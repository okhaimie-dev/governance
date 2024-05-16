use starknet::{ContractAddress};

#[starknet::interface]
pub trait IFungibleStakedToken<TContractState> {
    // Returns the address of the staker that this staked token wrapper uses
    fn get_staker(self: @TContractState) -> ContractAddress;

    // Get the address to whom the owner is delegated to
    fn get_delegated_to(self: @TContractState, owner: ContractAddress) -> ContractAddress;

    // Returns the total number of tokens currently staked
    fn get_total_staked(self: @TContractState) -> u128;

    // The number of seconds (while total staked > 0) that have passed per total tokens staked
    // Can be used to compute the share of total staked tokens that a user has had over a period, by collecting two snapshots of the value
    fn get_seconds_per_total_staked(self: @TContractState, timestamp: u64) -> u256;

    // Delegates any staked tokens from the caller to the owner
    fn delegate(ref self: TContractState, to: ContractAddress);

    // Transfers the approved amount of the staked token to this contract and mints an ERC20 representing the staked amount
    fn deposit(ref self: TContractState);

    // Same as above but with a specified amount
    fn deposit_amount(ref self: TContractState, amount: u128);

    // Withdraws the entire staked balance from the contract from the caller
    fn withdraw(ref self: TContractState);

    // Withdraws the specified amount of token from the contract from the caller
    fn withdraw_amount(ref self: TContractState, amount: u128);
}

#[starknet::contract]
pub mod FungibleStakedToken {
    use core::num::traits::zero::{Zero};
    use core::option::{OptionTrait};
    use core::traits::{Into, TryInto};
    use governance::interfaces::erc20::{IERC20, IERC20Dispatcher, IERC20DispatcherTrait};
    use governance::staker::{IStakerDispatcher, IStakerDispatcherTrait};
    use starknet::{
        get_caller_address, get_contract_address, get_block_timestamp,
        storage_access::{StorePacking}
    };
    use super::{IFungibleStakedToken, ContractAddress};


    #[derive(Copy, Drop, PartialEq, Debug)]
    pub struct StakedSnapshot {
        pub timestamp: u64,
        pub seconds_per_total_staked: u256,
    }

    const TWO_POW_64: u128 = 0x10000000000000000;
    const TWO_POW_192: u256 = 0x1000000000000000000000000000000000000000000000000;
    const TWO_POW_192_DIVISOR: NonZero<u256> = 0x1000000000000000000000000000000000000000000000000;

    // todo: refactor to reuse the code from the delegated snapshot
    pub(crate) impl StakedSnapshotStorePacking of StorePacking<StakedSnapshot, felt252> {
        fn pack(value: StakedSnapshot) -> felt252 {
            assert(value.seconds_per_total_staked < TWO_POW_192, 'MAX_SECONDS_PER_TOTAL_STAKED');
            (value.seconds_per_total_staked
                + u256 { high: value.timestamp.into() * TWO_POW_64, low: 0 })
                .try_into()
                .unwrap()
        }

        fn unpack(value: felt252) -> StakedSnapshot {
            let (timestamp, seconds_per_total_staked) = DivRem::div_rem(
                value.into(), TWO_POW_192_DIVISOR
            );
            StakedSnapshot {
                timestamp: timestamp.low.try_into().unwrap(), seconds_per_total_staked
            }
        }
    }


    #[storage]
    struct Storage {
        staker: IStakerDispatcher,
        delegated_to: LegacyMap<ContractAddress, ContractAddress>,
        total_staked: u128,
        num_snapshots: u64,
        snapshots_by_index: LegacyMap<u64, StakedSnapshot>,
        balances: LegacyMap<ContractAddress, u128>,
        allowances: LegacyMap<(ContractAddress, ContractAddress), u128>,
    }

    #[constructor]
    fn constructor(ref self: ContractState, staker: IStakerDispatcher) {
        self.staker.write(staker);
    }

    #[derive(starknet::Event, PartialEq, Debug, Drop)]
    pub struct Deposit {
        pub from: ContractAddress,
        pub amount: u128,
    }

    #[derive(starknet::Event, PartialEq, Debug, Drop)]
    pub struct Withdrawal {
        pub from: ContractAddress,
        pub amount: u128,
    }


    #[derive(starknet::Event, PartialEq, Debug, Drop)]
    pub struct Delegation {
        pub from: ContractAddress,
        pub to: ContractAddress,
    }

    #[derive(starknet::Event, PartialEq, Debug, Drop)]
    pub struct Transfer {
        pub from: ContractAddress,
        pub to: ContractAddress,
        pub amount: u256,
    }
    #[derive(starknet::Event, PartialEq, Debug, Drop)]
    pub struct Approval {
        pub owner: ContractAddress,
        pub spender: ContractAddress,
        pub amount: u256,
    }

    #[derive(starknet::Event, Drop)]
    #[event]
    enum Event {
        Deposit: Deposit,
        Withdrawal: Withdrawal,
        Delegation: Delegation,
        Transfer: Transfer,
        Approval: Approval,
    }

    #[generate_trait]
    impl InternalMethods of InternalMethodsTrait {
        fn move_delegates(
            self: @ContractState, from: ContractAddress, to: ContractAddress, amount: u128
        ) {
            let staker = self.staker.read();
            let token = IERC20Dispatcher { contract_address: staker.get_token() };

            staker.withdraw_amount(from, get_contract_address(), amount);
            assert(token.approve(staker.contract_address, amount.into()), 'APPROVE_FAILED');
            staker.stake(to);
        }

        fn last_staked_snapshot(self: @ContractState) -> (u64, StakedSnapshot) {
            let index = self.num_snapshots.read();
            (index, self.snapshots_by_index.read(index))
        }

        fn snapshot_total_staked_last(ref self: ContractState) -> u128 {
            let total_staked = self.total_staked.read();
            let current_time = get_block_timestamp();
            let (index, last_snapshot) = self.last_staked_snapshot();
            let time_elapsed = current_time - last_snapshot.timestamp;
            if time_elapsed.is_non_zero() {
                let next = index + 1;
                self.num_snapshots.write(next);
                self
                    .snapshots_by_index
                    .write(
                        next,
                        StakedSnapshot {
                            seconds_per_total_staked: last_snapshot.seconds_per_total_staked
                                + (u256 { high: time_elapsed.into(), low: 0 } / total_staked.into())
                                    .try_into()
                                    .unwrap(),
                            timestamp: current_time,
                        }
                    );
            }
            total_staked
        }

        fn find_seconds_per_total_staked(
            self: @ContractState, min_index: u64, max_index_exclusive: u64, timestamp: u64
        ) -> u256 {
            if (min_index == (max_index_exclusive - 1)) {
                let snapshot = self.snapshots_by_index.read(min_index);
                return if (snapshot.timestamp > timestamp) {
                    0
                } else {
                    let difference = timestamp - snapshot.timestamp;
                    let next = self.snapshots_by_index.read(min_index + 1);
                    let staked_amount = if (next.timestamp.is_zero()) {
                        self.total_staked.read()
                    } else {
                        // todo: this is wrong because it increments by seconds / total_staked, not total_staked * seconds
                        (u256 { high: (next.timestamp - snapshot.timestamp).into(), low: 0 }
                            / (next.seconds_per_total_staked - snapshot.seconds_per_total_staked))
                            .try_into()
                            .unwrap()
                    };

                    // todo: is rounding safe here?
                    snapshot.seconds_per_total_staked + (difference.into() / staked_amount).into()
                };
            }
            let mid = (min_index + max_index_exclusive) / 2;

            let snapshot = self.snapshots_by_index.read(mid);

            if (timestamp == snapshot.timestamp) {
                return snapshot.seconds_per_total_staked;
            }

            // timestamp we are looking for is before snapshot
            if (timestamp < snapshot.timestamp) {
                self.find_seconds_per_total_staked(min_index, mid, timestamp)
            } else {
                self.find_seconds_per_total_staked(mid, max_index_exclusive, timestamp)
            }
        }
    }

    #[abi(embed_v0)]
    impl FungibleStakedTokenERC20 of IERC20<ContractState> {
        fn balanceOf(self: @ContractState, account: ContractAddress) -> u256 {
            self.balances.read(account).into()
        }
        fn allowance(
            self: @ContractState, owner: ContractAddress, spender: ContractAddress
        ) -> u256 {
            self.allowances.read((owner, spender)).into()
        }
        fn transfer(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
            let from = get_caller_address();
            let balance = self.balances.read(from);
            assert(balance.into() >= amount, 'INSUFFICIENT_BALANCE');
            let small_amount: u128 = amount.try_into().unwrap();
            self.balances.write(from, balance - small_amount);
            self.balances.write(recipient, self.balances.read(recipient) + small_amount);
            self.emit(Transfer { from, to: recipient, amount: amount });
            self
                .move_delegates(
                    self.get_delegated_to(from), self.get_delegated_to(recipient), small_amount
                );
            true
        }
        fn transferFrom(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256
        ) -> bool {
            let spender = get_caller_address();
            let allowance = self.allowances.read((sender, spender));
            assert(allowance.into() >= amount, 'INSUFFICIENT_ALLOWANCE');
            let small_amount: u128 = amount.try_into().unwrap();
            self.allowances.write((sender, spender), allowance - small_amount);

            let balance = self.balances.read(sender);

            self.balances.write(sender, balance - small_amount);
            self.balances.write(recipient, self.balances.read(recipient) + small_amount);
            self.emit(Transfer { from: sender, to: recipient, amount: amount });

            self
                .move_delegates(
                    self.get_delegated_to(sender), self.get_delegated_to(recipient), small_amount
                );

            true
        }
        fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
            let owner = get_caller_address();
            let small_amount: u128 = amount.try_into().expect('AMOUNT_EXCEEDS_U128');
            self.allowances.write((owner, spender), small_amount);
            self.emit(Approval { owner, spender, amount });
            true
        }
    }

    #[abi(embed_v0)]
    impl FungibleStakedTokenImpl of IFungibleStakedToken<ContractState> {
        fn get_staker(self: @ContractState) -> ContractAddress {
            self.staker.read().contract_address
        }

        fn get_delegated_to(self: @ContractState, owner: ContractAddress) -> ContractAddress {
            self.delegated_to.read(owner)
        }

        fn get_total_staked(self: @ContractState) -> u128 {
            self.total_staked.read()
        }

        fn get_seconds_per_total_staked(self: @ContractState, timestamp: u64) -> u256 {
            assert(timestamp <= get_block_timestamp(), 'FUTURE');

            let num_snapshots = self.num_snapshots.read();
            return if (num_snapshots.is_zero()) {
                0
            } else {
                self
                    .find_seconds_per_total_staked(
                        min_index: 0, max_index_exclusive: num_snapshots, timestamp: timestamp
                    )
            };
        }

        fn delegate(ref self: ContractState, to: ContractAddress) {
            let caller = get_caller_address();
            let previous_delegated_to = self.delegated_to.read(caller);
            self.delegated_to.write(caller, to);
            self
                .move_delegates(
                    previous_delegated_to, to, self.balanceOf(caller).try_into().unwrap()
                );
            self.emit(Delegation { from: caller, to });
        }

        fn deposit_amount(ref self: ContractState, amount: u128) {
            let staker = self.staker.read();
            let token = IERC20Dispatcher { contract_address: staker.get_token() };
            let caller = get_caller_address();
            assert(
                token.transferFrom(caller, get_contract_address(), amount.into()),
                'TRANSFER_FROM_FAILED'
            );
            assert(token.approve(staker.contract_address, amount.into()), 'APPROVE_FAILED');
            staker.stake(self.delegated_to.read(caller));

            self.balances.write(caller, self.balances.read(caller) + amount);
            self.total_staked.write(self.snapshot_total_staked_last() + amount);
        }

        fn deposit(ref self: ContractState) {
            self
                .deposit_amount(
                    IERC20Dispatcher { contract_address: self.staker.read().get_token() }
                        .allowance(get_caller_address(), get_contract_address())
                        .try_into()
                        .unwrap()
                );
        }

        fn withdraw_amount(ref self: ContractState, amount: u128) {
            let staker = self.staker.read();
            let caller = get_caller_address();
            staker.withdraw_amount(self.delegated_to.read(caller), caller, amount);
            self.balances.write(caller, self.balances.read(caller) - amount);
            self.total_staked.write(self.snapshot_total_staked_last() - amount);
        }

        fn withdraw(ref self: ContractState) {
            self.withdraw_amount(self.balanceOf(get_caller_address()).try_into().unwrap());
        }
    }
}
