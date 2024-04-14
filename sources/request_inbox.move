

module hermes::request_inbox {

    use std::signer;
    use std::string;
    use std::vector;
    use aptos_framework::account;
    use aptos_framework::account::SignerCapability;
    use aptos_framework::event::emit;
    use aptos_framework::timestamp;
    #[test_only]
    use aptos_std::debug;
    #[test_only]
    use aptos_framework::event::emitted_events;

    friend hermes::message_inbox;

    const SEED: vector<u8> = b"request inbox";

    const EINBOX_NOT_REGISTERED: u64 = 0;
    const EUSER_NOT_PERMITTED: u64 = 1;
    const ECONVERSATION_INVITE_NOT_ACCEPTED: u64 = 3;
    const EREQUEST_ALREADY_EXISTS: u64 = 4;
    const EALREADY_IN_PHONEBOOK: u64 = 5;
    const ERequestNotInPending: u64 = 6;

    struct Request has store, drop, copy {
        address: address,
        timestamp: u64,
        envelop: string::String
    }

    #[event]
    struct RequestInboxRegisterEvent has store, drop, copy {
        user_address: address,
        timestamp: u64,
    }

    #[event]
    struct RequestEvent has store, drop, copy {
        requester_address: address,
        inbox_owner_address: address,
        envelope: string::String,
        timestamp: u64
    }

    #[event]
    struct AcceptRequestEvent has store, drop, copy {
        requester_address: address,
        inbox_owner_address: address,
        timestamp: u64
    }

    #[event]
    struct RequestDeniedEvent has store, drop, copy  {
        requester_address: address,
        inbox_owner_address: address,
        timestamp: u64
    }

    #[event]
    struct RequestRemoveFromPhoneBookEvent has store, drop {
        inbox_owner_address: address,
        timestamp: u64,
        requester_address: address,
    }

    struct RequestInbox has key {
        pending_requests: vector<Request>,
        phone_book: vector<Request>
    }

    struct State has key {
        signer_capability: SignerCapability
    }

    fun init_module(admin: &signer) {
        let (resource_signer,signer_capability) = account::create_resource_account(admin, SEED);

        move_to(&resource_signer, State {
            signer_capability
        })
    }

    public fun register_request_inbox(user: &signer) {
        // TODO: assert user has a kade username
        move_to(user, RequestInbox {
            pending_requests: vector::empty(),
            phone_book: vector::empty()
        });

        emit(RequestInboxRegisterEvent {
            timestamp: timestamp::now_microseconds(),
            user_address: signer::address_of(user)
        })
    }

    public fun request_conversation(requester: &signer, user_address: address, envelope: string::String) acquires RequestInbox {
        assert!(exists<RequestInbox>(signer::address_of(requester)), EINBOX_NOT_REGISTERED);
        assert!(exists<RequestInbox>(user_address), EINBOX_NOT_REGISTERED);

        assert_does_not_exist_in_phonebook(user_address, signer::address_of(requester));
        assert_has_not_previously_requested(user_address, signer::address_of(requester));

        let newRequest = Request {
            address: signer::address_of(requester),
            timestamp: timestamp::now_microseconds(),
            envelop: envelope
        };

        let inbox = borrow_global_mut<RequestInbox>(user_address);

        vector::push_back(&mut inbox.pending_requests, newRequest);

        emit(RequestEvent {
            envelope,
            inbox_owner_address: user_address,
            requester_address: signer::address_of(requester),
            timestamp: timestamp::now_microseconds()
        })
    }

    public fun accept_request(user: &signer, requester_address: address) acquires RequestInbox {
        let user_address = signer::address_of(user);
        assert!(exists<RequestInbox>(user_address), EINBOX_NOT_REGISTERED);
        assert!(exists<RequestInbox>(requester_address), EINBOX_NOT_REGISTERED);
        assert_is_pending(user_address, requester_address);
        assert_does_not_exist_in_phonebook(user_address, requester_address);

        let inbox = borrow_global_mut<RequestInbox>(signer::address_of(user));

        let (exists, index) = vector::find(&inbox.pending_requests, |request|{
            let req: &Request = request;
            req.address == requester_address
        });

        assert!(exists, ERequestNotInPending);

        let request = vector::remove(&mut inbox.pending_requests, index);

        vector::push_back(&mut inbox.phone_book, request);

        emit(AcceptRequestEvent {
            requester_address,
            timestamp: timestamp::now_microseconds(),
            inbox_owner_address: user_address
        })

    }

    public fun deny_request(user: &signer, requester_address: address) acquires RequestInbox {
        let user_address = signer::address_of(user);
        assert_has_inbox(user_address);
        assert_has_inbox(requester_address);
        assert_is_pending(user_address, requester_address);

        let inbox = borrow_global_mut<RequestInbox>(signer::address_of((user)));

        let (_, index) = vector::find(&inbox.pending_requests, |request|{
            let req: &Request = request;
            req.address == requester_address
        });

        vector::remove(&mut inbox.pending_requests, index);

        emit(RequestDeniedEvent {
            requester_address,
            inbox_owner_address: user_address,
            timestamp: timestamp::now_microseconds(),
        })
    }

    public fun remove_from_phone_book(user: &signer, unwanted_address: address) acquires RequestInbox {
        let user_address = signer::address_of(user);
        assert_has_inbox(user_address);
        assert_has_inbox(unwanted_address);
        assert_is_in_inbox(user_address, unwanted_address);

        let inbox = borrow_global_mut<RequestInbox>(signer::address_of(user));

        let (_, index) = vector::find(&inbox.phone_book, |request|{
            let req: &Request = request;
            req.address == unwanted_address
        });

        vector::remove(&mut inbox.phone_book, index);

        emit(RequestRemoveFromPhoneBookEvent {
            timestamp: timestamp::now_microseconds(),
            inbox_owner_address: user_address,
            requester_address: unwanted_address,
        })
    }


    public(friend) fun assert_is_in_inbox(user_address: address, sender_address: address) acquires RequestInbox {
        assert!(exists<RequestInbox>(user_address), EINBOX_NOT_REGISTERED);
        assert!(exists<RequestInbox>(sender_address), EINBOX_NOT_REGISTERED);
        let user_inbox = borrow_global<RequestInbox>(user_address);

        let (exists, _) = vector::find(&user_inbox.phone_book, |request|{
            let req: &Request = request;

            req.address == sender_address
        });

        assert!(exists, ECONVERSATION_INVITE_NOT_ACCEPTED);

    }

    inline fun assert_is_pending(user_address: address, requester_address: address) acquires  RequestInbox {
        let user_inbox = borrow_global<RequestInbox>(user_address);

        let (exists, _) = vector::find(&user_inbox.pending_requests, |request|{
            let req: &Request = request;

            req.address == requester_address
        });

        assert!(exists, ERequestNotInPending);
    }

    public(friend) fun assert_has_inbox(user_address: address) {
        assert!(exists<RequestInbox>(user_address),EINBOX_NOT_REGISTERED);
    }

    inline fun assert_has_not_previously_requested(inbox_owner: address, requester_address: address) acquires  RequestInbox {
        let inbox = borrow_global<RequestInbox>(inbox_owner);

        let (exists, _) = vector::find(&inbox.pending_requests, |request|{
            let req: &Request = request;

            req.address == requester_address
        });

        assert!(!exists, EREQUEST_ALREADY_EXISTS);
    }

    inline fun assert_does_not_exist_in_phonebook(inbox_owner: address, requester_address: address) acquires  RequestInbox {

        let inbox = borrow_global<RequestInbox>(inbox_owner);

        let (exists, _) = vector::find(&inbox.phone_book, |request| {
            let req: &Request = request;

            req.address == requester_address
        });

        assert!(!exists, EALREADY_IN_PHONEBOOK);

    }

    #[test_only]
    public(friend) fun init_for_test(admin: &signer) {
        init_module(admin);
    }


    //====
    // Tests
    //====
    #[test]
    fun test_init() acquires  State {
        let admin = account::create_account_for_test(@hermes);

        init_module(&admin);

        let resource_address = account::create_resource_address(&@hermes, SEED);

        assert!(exists<State>(resource_address), 0);
        let state = borrow_global<State>(resource_address);
        debug::print(state);
    }

    #[test]
    fun test_register_inbox() {

        let admin = account::create_account_for_test(@hermes);
        let user_account = account::create_account_for_test(@0x321);
        let aptos_framework = account::create_account_for_test(@0x1);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        init_module(&admin);

        register_request_inbox(&user_account);

        let events = emitted_events<RequestInboxRegisterEvent>();
        assert!(vector::length(&events) == 1, 0);

        debug::print(&events);
    }

    #[test]
    fun test_make_conversation_request() acquires RequestInbox {

        let admin = account::create_account_for_test(@hermes);
        let user_account = account::create_account_for_test(@0x321);
        let second_user_account = account::create_account_for_test(@0x3261);
        let aptos_framework = account::create_account_for_test(@0x1);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        init_module(&admin);

        register_request_inbox(&user_account);
        register_request_inbox(&second_user_account);

        request_conversation(&second_user_account, signer::address_of(&user_account), string::utf8(b""));

        let register_events = emitted_events<RequestInboxRegisterEvent>();

        assert!(vector::length(&register_events) == 2, 0);

        let request_events = emitted_events<RequestEvent>();

        assert!(vector::length(&request_events) == 1, 1);

        debug::print(&request_events);
    }

    #[test]
    fun test_accept_conversation_request() acquires RequestInbox {
        let admin = account::create_account_for_test(@hermes);
        let user_account = account::create_account_for_test(@0x321);
        let second_user_account = account::create_account_for_test(@0x3261);
        let aptos_framework = account::create_account_for_test(@0x1);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        init_module(&admin);

        register_request_inbox(&user_account);
        register_request_inbox(&second_user_account);

        request_conversation(&second_user_account, signer::address_of(&user_account), string::utf8(b""));

        accept_request(&user_account, signer::address_of(&second_user_account));

        let register_events = emitted_events<RequestInboxRegisterEvent>();

        assert!(vector::length(&register_events) == 2, 0);

        let request_events = emitted_events<RequestEvent>();

        assert!(vector::length(&request_events) == 1, 1);

        let accept_events = emitted_events<AcceptRequestEvent>();

        assert!(vector::length(&accept_events) == 1, 2);

        debug::print(&accept_events);
    }

    #[test]
    fun test_deny_conversation_request() acquires RequestInbox {
        let admin = account::create_account_for_test(@hermes);
        let user_account = account::create_account_for_test(@0x321);
        let second_user_account = account::create_account_for_test(@0x3261);
        let aptos_framework = account::create_account_for_test(@0x1);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        init_module(&admin);

        register_request_inbox(&user_account);
        register_request_inbox(&second_user_account);

        request_conversation(&second_user_account, signer::address_of(&user_account), string::utf8(b""));

        deny_request(&user_account, signer::address_of(&second_user_account));

        let register_events = emitted_events<RequestInboxRegisterEvent>();

        assert!(vector::length(&register_events) == 2, 0);

        let request_events = emitted_events<RequestEvent>();

        assert!(vector::length(&request_events) == 1, 1);

        let deny_events = emitted_events<RequestDeniedEvent>();

        assert!(vector::length(&deny_events) == 1, 2);
    }

    #[test]
    fun test_remove_from_phonebook() acquires RequestInbox {
        let admin = account::create_account_for_test(@hermes);
        let user_account = account::create_account_for_test(@0x321);
        let second_user_account = account::create_account_for_test(@0x3261);
        let aptos_framework = account::create_account_for_test(@0x1);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        init_module(&admin);

        register_request_inbox(&user_account);
        register_request_inbox(&second_user_account);

        request_conversation(&second_user_account, signer::address_of(&user_account), string::utf8(b""));

        accept_request(&user_account, signer::address_of(&second_user_account));

        remove_from_phone_book(&user_account, signer::address_of(&second_user_account));

        let register_events = emitted_events<RequestInboxRegisterEvent>();

        assert!(vector::length(&register_events) == 2, 0);

        let request_events = emitted_events<RequestEvent>();

        assert!(vector::length(&request_events) == 1, 1);

        let accept_events = emitted_events<AcceptRequestEvent>();

        assert!(vector::length(&accept_events) == 1, 2);

        let remove_events = emitted_events<RequestRemoveFromPhoneBookEvent>();

        assert!(vector::length(&remove_events) == 1, 3);

    }

}
