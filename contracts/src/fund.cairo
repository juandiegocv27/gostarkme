use starknet::ContractAddress;

#[starknet::interface]
pub trait IFund<TContractState> {
    fn getId(self: @TContractState) -> u128;
    fn getOwner(self: @TContractState) -> ContractAddress;
    fn setName(ref self: TContractState, name: felt252);
    fn getName(self: @TContractState) -> felt252;
    fn setReason(ref self: TContractState, reason: ByteArray);
    fn getReason(self: @TContractState) -> ByteArray;
    fn receiveVote(ref self: TContractState);
    fn getUpVotes(self: @TContractState) -> u32;
    fn setGoal(ref self: TContractState, goal: u256);
    fn getGoal(self: @TContractState) -> u256;
    fn receiveDonation(ref self: TContractState, strks: u256);
    fn get_current_goal_state(self: @TContractState) -> u256;
    fn setState(ref self: TContractState, state: u8);
    fn getState(self: @TContractState) -> u8;
    fn getVoter(self: @TContractState) -> u32;
    fn withdraw(ref self: TContractState);
}

#[starknet::contract]
mod Fund {
    // *************************************************************************
    //                            IMPORT
    // *************************************************************************
    use starknet::ContractAddress;
    use starknet::get_caller_address;
    use starknet::contract_address_const;
    use starknet::get_contract_address;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use gostarkme::constants::{funds::{state_constants::FundStates},};
    use gostarkme::constants::{
        funds::{fund_constants::FundConstants, fund_manager_constants::FundManagerConstants},
    };
    use gostarkme::constants::{funds::{starknet_constants::StarknetConstants},};

    // *************************************************************************
    //                            EVENTS
    // *************************************************************************
    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        DonationWithdraw: DonationWithdraw,
        NewVoteReceived: NewVoteReceived,
        DonationReceived: DonationReceived,
    }

    #[derive(Drop, starknet::Event)]
    pub struct DonationWithdraw {
        #[key]
        pub owner_address: ContractAddress,
        pub fund_contract_address: ContractAddress,
        pub withdrawn_amount: u256
    }

    #[derive(Drop, starknet::Event)]
    pub struct NewVoteReceived {
        #[key]
        pub voter: ContractAddress,
        pub fund: ContractAddress,
        pub votes: u32
    }

    #[derive(Drop, starknet::Event)]
    pub struct DonationReceived {
        #[key]
        pub donator_address: ContractAddress,
        pub current_balance: u256,
        pub donated_strks: u256,
        pub fund_contract_address: ContractAddress,
    }
    // *************************************************************************
    //                            STORAGE
    // *************************************************************************
    #[storage]
    struct Storage {
        id: u128,
        owner: ContractAddress,
        name: felt252,
        reason: ByteArray,
        up_votes: u32,
        voters: LegacyMap::<ContractAddress, u32>,
        goal: u256,
        state: u8,
    }

    // *************************************************************************
    //                            CONSTRUCTOR
    // *************************************************************************
    #[constructor]
    fn constructor(
        ref self: ContractState, id: u128, owner: ContractAddress, name: felt252, goal: u256
    ) {
        self.id.write(id);
        self.owner.write(owner);
        self.name.write(name);
        self.reason.write(" ");
        self.up_votes.write(FundConstants::INITIAL_UP_VOTES);
        self.goal.write(goal);
        self.state.write(FundStates::RECOLLECTING_VOTES);
    }

    // *************************************************************************
    //                            EXTERNALS
    // *************************************************************************
    #[abi(embed_v0)]
    impl FundImpl of super::IFund<ContractState> {
        fn getId(self: @ContractState) -> u128 {
            return self.id.read();
        }
        fn getOwner(self: @ContractState) -> ContractAddress {
            return self.owner.read();
        }
        fn setName(ref self: ContractState, name: felt252) {
            let caller = get_caller_address();
            assert!(self.owner.read() == caller, "You are not the owner");
            self.name.write(name);
        }
        fn getName(self: @ContractState) -> felt252 {
            return self.name.read();
        }
        fn setReason(ref self: ContractState, reason: ByteArray) {
            let caller = get_caller_address();
            assert!(self.owner.read() == caller, "You are not the owner");
            self.reason.write(reason);
        }
        fn getReason(self: @ContractState) -> ByteArray {
            return self.reason.read();
        }
        fn receiveVote(ref self: ContractState) {
            assert(self.voters.read(get_caller_address()) == 0, 'User already voted!');
            assert(
                self.state.read() == FundStates::RECOLLECTING_VOTES, 'Fund not recollecting votes!'
            );
            self.up_votes.write(self.up_votes.read() + 1);
            self.voters.write(get_caller_address(), self.up_votes.read());
            if self.up_votes.read() >= FundConstants::UP_VOTES_NEEDED {
                self.state.write(FundStates::RECOLLECTING_DONATIONS);
            }

            self
                .emit(
                    NewVoteReceived {
                        voter: get_caller_address(),
                        fund: get_contract_address(),
                        votes: self.up_votes.read()
                    }
                );
        }
        fn getUpVotes(self: @ContractState) -> u32 {
            return self.up_votes.read();
        }
        fn setGoal(ref self: ContractState, goal: u256) {
            let caller = get_caller_address();
            let fund_manager_address = contract_address_const::<
                FundManagerConstants::FUND_MANAGER_ADDRESS
            >();
            assert!(fund_manager_address == caller, "You are not the fund manager");
            self.goal.write(goal);
        }
        fn getGoal(self: @ContractState) -> u256 {
            return self.goal.read();
        }
        // TODO: implement the logic where user actually donates starks
        fn receiveDonation(ref self: ContractState, strks: u256) {
            assert(
                self.state.read() == FundStates::RECOLLECTING_DONATIONS,
                'Fund not recollecting dons!'
            );
            self
                .token_dispatcher()
                .transfer_from(get_caller_address(), get_contract_address(), strks);
            let current_balance = self.get_current_goal_state();
            if current_balance >= self.goal.read() {
                self.state.write(FundStates::CLOSED);
            }

            // Emit receiveDonation event
            self
                .emit(
                    DonationReceived {
                        current_balance,
                        donated_strks: strks,
                        donator_address: get_caller_address(),
                        fund_contract_address: get_contract_address(),
                    }
                )
        }
        fn get_current_goal_state(self: @ContractState) -> u256 {
            self.token_dispatcher().balance_of(get_contract_address())
        }
        fn setState(ref self: ContractState, state: u8) {
            self.state.write(state);
        }
        fn getState(self: @ContractState) -> u8 {
            return self.state.read();
        }
        fn getVoter(self: @ContractState) -> u32 {
            return self.voters.read(get_caller_address());
        }
        fn withdraw(ref self: ContractState) {
            // Verifications
            let caller = get_caller_address();
            assert!(self.owner.read() == caller, "You are not the owner");
            assert(self.state.read() == FundStates::CLOSED, 'Fund not close goal yet.');
            assert(self.get_current_goal_state() > 0, 'Fund hasnt reached its goal yet');
            // Withdraw
            let withdrawn_amount = self.get_current_goal_state();
            // TODO: Calculate balance to deposit in owner address and in fund manager address (95%
            // and 5%), also transfer the amount to fund manager address.
            self.token_dispatcher().transfer(self.getOwner(), withdrawn_amount);
            assert(self.get_current_goal_state() != 0, 'Fund hasnt reached its goal yet');
            self.setState(4);
            self
                .emit(
                    DonationWithdraw {
                        owner_address: self.getOwner(),
                        fund_contract_address: get_contract_address(),
                        withdrawn_amount
                    }
                );
        }
    }
    // *************************************************************************
    //                            INTERNALS
    // *************************************************************************
    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn token_dispatcher(self: @ContractState) -> IERC20Dispatcher {
            IERC20Dispatcher {
                contract_address: contract_address_const::<StarknetConstants::STRK_TOKEN_ADDRESS>()
            }
        }
    }
}
