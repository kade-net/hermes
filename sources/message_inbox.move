
module hermes::message_inbox {

    use std::signer;
    use std::string;
    use aptos_framework::account;
    use aptos_framework::event::emit;
    use aptos_framework::timestamp;
    use hermes::request_inbox;
    #[test_only]
    use std::vector;
    #[test_only]
    use aptos_std::debug;
    #[test_only]
    use aptos_framework::event::emitted_events;

    const SEED: vector<u8> = b"message_inbox";

    #[event]
    struct Envelope has store, drop {
        sender: address,
        receiver: address,
        content: string::String,
        timestamp: u64,
        hid: u64,
        ref: string::String
    }


    struct State has key {
        signer_capability: account::SignerCapability,
        message_hid: u64
    }

    fun init_module(admin: &signer) {

        let (resource_signer, signer_capability) = account::create_resource_account(admin, SEED);

        move_to(&resource_signer, State {
            signer_capability,
            message_hid: 100 // reserve the first 100 hids for error codes and other system messages
        })

    }

    fun send_envelope(user: &signer, receiver_address: address, content: string::String, ref: string::String) acquires  State {

        let sender_address = signer::address_of(user);
        request_inbox::assert_has_inbox(sender_address);
        request_inbox::assert_has_inbox(receiver_address);
        request_inbox::assert_is_in_inbox(receiver_address, sender_address);

        let resource_address = account::create_resource_address(&@hermes, SEED);

        let state = borrow_global_mut<State>(resource_address);

        let current_hid = state.message_hid;

        state.message_hid = state.message_hid + 1;

        emit(Envelope {
            timestamp: timestamp::now_microseconds(),
            content,
            hid: current_hid,
            receiver: receiver_address,
            sender: sender_address,
            ref
        })

    }


    // =====
    // Tests
    // =====
    #[test]
    fun test_init(){
        let admin = account::create_account_for_test(@hermes);

        init_module(&admin);
    }

    #[test]
    fun test_send_envelope() acquires State {
        let admin =account::create_account_for_test(@hermes);
        let user_account = account::create_account_for_test(@0x321);
        let second_user_account = account::create_account_for_test(@0x3216);

        let aptos_framework = account::create_account_for_test(@0x1);

        timestamp::set_time_has_started_for_testing(&aptos_framework);

        init_module(&admin);

        request_inbox::init_for_test(&admin);

        request_inbox::register_request_inbox(&user_account);
        request_inbox::register_request_inbox(&second_user_account);

        request_inbox::request_conversation(&second_user_account, signer::address_of(&user_account), string::utf8(b""));

        request_inbox::accept_request(&user_account, signer::address_of(&second_user_account));

        send_envelope(&second_user_account, signer::address_of(&user_account), string::utf8(b""), string::utf8(b""));

        let envelopes = emitted_events<Envelope>();

        debug::print(&envelopes);

        assert!(vector::length(&envelopes) == 1, 2);


    }




}
