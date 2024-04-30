

module hermes::request_inbox {

    use std::option;
    use std::option::Option;
    use std::signer;
    use std::string;
    use std::vector;
    use aptos_std::string_utils;
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
    const ENoPendingLinkIntent: u64 = 7;
    const EDelegateNotAccepted: u64 = 8;
    const EDelegateAlreadyTaken: u64 = 9;
    const EUnkownDelegate: u64 = 10;
    const EUserDoesNotOwnDelegate: u64 = 11;
    const ENoDelegateFound: u64 = 12;

    struct Request has store, drop, copy {
        address: address,
        timestamp: u64,
        envelope: string::String,
        connection_owner: address
    }

    #[event]
    struct RequestInboxRegisterEvent has store, drop, copy {
        user_address: address,
        timestamp: u64,
        hid: u64,
        public_key: string::String
    }

    #[event]
    struct RequestEvent has store, drop, copy {
        requester_address: address,
        inbox_owner_address: address,
        envelope: string::String,
        timestamp: u64,
        inbox_name: string::String,
    }

    #[event]
    struct AcceptRequestEvent has store, drop, copy {
        requester_address: address,
        inbox_owner_address: address,
        timestamp: u64,
        inbox_name: string::String
    }

    #[event]
    struct RequestDeniedEvent has store, drop, copy  {
        requester_address: address,
        inbox_owner_address: address,
        timestamp: u64,
        inbox_name: string::String
    }

    #[event]
    struct RequestRemoveFromPhoneBookEvent has store, drop {
        inbox_owner_address: address,
        timestamp: u64,
        requester_address: address,
        inbox_name: string::String
    }

    #[event]
    struct DelegateRegisterEvent has store, drop {
        owner: address,
        delegate_hid: u64,
        user_hid: u64,
        delegate_address: address,
    }

    #[event]
    struct DelegateRemoveEvent has store, drop {
        delegate_address: address,
        delegate_hid: u64,
        owner_address: address,
        owner_hid: u64,
    }

    struct RequestInbox has key {
        pending_requests: vector<Request>,
        phone_book: vector<Request>,
        pending_delegate_link: Option<address>,
        hid: u64,
        public_key: string::String
    }

    struct Delegate has key, drop {
        owner_address: address,
        timestamp: u64,
        hid: u64
    }

    struct State has key {
        signer_capability: SignerCapability,
        registered_inboxes: u64,
        registered_delegates: u64,
    }

    fun init_module(admin: &signer) {
        let (resource_signer,signer_capability) = account::create_resource_account(admin, SEED);

        move_to(&resource_signer, State {
            signer_capability,
            registered_delegates: 100, // Reserve the first 100 for system use
            registered_inboxes: 100, // Reserve the first 100 for system use
        })
    }

    public entry fun register_request_inbox(user: &signer, pub: string::String) acquires State {
        // TODO: assert user has a kade username

        let resource_address = account::create_resource_address(&@hermes, SEED);

        let state = borrow_global_mut<State>(resource_address);

        let user_id = state.registered_inboxes;

        state.registered_inboxes = state.registered_inboxes + 1;

        move_to(user, RequestInbox {
            pending_requests: vector::empty(),
            phone_book: vector::empty(),
            pending_delegate_link: option::none(),
            hid: user_id,
            public_key: pub
        });

        emit(RequestInboxRegisterEvent {
            timestamp: timestamp::now_microseconds(),
            user_address: signer::address_of(user),
            hid: user_id,
            public_key: pub
        })
    }

    public entry fun create_delegate_link_intent(user: &signer, delegate_address: address) acquires RequestInbox {
        let user_address = signer::address_of(user);

        let inbox = borrow_global_mut<RequestInbox>(user_address);
        inbox.pending_delegate_link = option::some(delegate_address)
    }

    public entry fun register_delegate(delegate: &signer, user_address: address) acquires State, RequestInbox {
        let delegate_address = signer::address_of(delegate);
        let resource_address = account::create_resource_address(&@hermes, SEED);

        let inbox = borrow_global_mut<RequestInbox>(user_address);

        assert!(option::is_some(& inbox.pending_delegate_link), ENoPendingLinkIntent);
        assert!(!exists<Delegate>(delegate_address), EDelegateAlreadyTaken);

        let unlinked_delegate = *option::borrow(&inbox.pending_delegate_link);
        inbox.pending_delegate_link = option::none();

        assert!(unlinked_delegate == delegate_address, EDelegateNotAccepted);

        let state = borrow_global_mut<State>(resource_address);

        let hid = state.registered_delegates;

        state.registered_delegates = state.registered_delegates + 1;

        move_to(delegate, Delegate {
            hid,
            timestamp: timestamp::now_microseconds(),
            owner_address: user_address
        });

        emit(DelegateRegisterEvent {
            delegate_address,
            owner: user_address,
            delegate_hid: hid,
            user_hid: inbox.hid
        })

    }

    public entry fun remove_delegate(user: &signer, delegate_address: address) acquires Delegate, RequestInbox {
        let user_address = signer::address_of(user);
        let inbox = borrow_global<RequestInbox>(user_address);

        let delegate = move_from<Delegate>(delegate_address);

        assert!(delegate.owner_address == user_address, EUserDoesNotOwnDelegate);

        emit(DelegateRemoveEvent {
            delegate_address,
            delegate_hid: delegate.hid,
            owner_address: signer::address_of(user),
            owner_hid: inbox.hid,
        })

    }

    public entry fun request_conversation(requester: &signer, user_address: address, envelope: string::String) acquires RequestInbox {
        assert!(exists<RequestInbox>(signer::address_of(requester)), EINBOX_NOT_REGISTERED);
        assert!(exists<RequestInbox>(user_address), EINBOX_NOT_REGISTERED);

        assert_does_not_exist_in_phonebook(user_address, signer::address_of(requester));
        assert_has_not_previously_requested(user_address, signer::address_of(requester));

        let newRequest = Request {
            address: signer::address_of(requester),
            timestamp: timestamp::now_microseconds(),
            envelope,
            connection_owner: user_address,
        };

        let inbox = borrow_global_mut<RequestInbox>(user_address);

        vector::push_back(&mut inbox.pending_requests, newRequest);

        emit(RequestEvent {
            envelope,
            inbox_owner_address: user_address,
            requester_address: signer::address_of(requester),
            timestamp: timestamp::now_microseconds(),
            inbox_name: string_utils::format2(&b"{}:{}", user_address, signer::address_of(requester))
        })
    }

    public entry fun delegate_request_conversation(delegate: &signer, user_address: address, envelope: string::String) acquires RequestInbox, Delegate {
        let delegate_address = signer::address_of(delegate);
        let delegate_state = borrow_global<Delegate>(delegate_address);

        let delegate_owner_address = delegate_state.owner_address;

        assert_does_not_exist_in_phonebook(user_address, delegate_owner_address);
        assert_has_not_previously_requested(user_address, delegate_owner_address);

        let newRequest = Request {
            address: delegate_owner_address,
            timestamp: timestamp::now_microseconds(),
            envelope,
            connection_owner: user_address
        };

        let inbox = borrow_global_mut<RequestInbox>(user_address);

        vector::push_back(&mut inbox.pending_requests, newRequest);

        emit(RequestEvent {
            envelope,
            timestamp: timestamp::now_microseconds(),
            requester_address: delegate_owner_address,
            inbox_owner_address: user_address,
            inbox_name: string_utils::format2(&b"{}:{}", user_address, delegate_owner_address)
        });

    }

    public entry fun accept_request(user: &signer, requester_address: address) acquires RequestInbox {
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

        add_to_phonebook(user_address, requester_address, request.envelope, request.connection_owner);
        add_to_phonebook(requester_address, user_address, request.envelope, request.connection_owner);

        let inbox_name = get_formatted_inbox_name(requester_address, user_address);

        emit(AcceptRequestEvent {
            requester_address,
            timestamp: timestamp::now_microseconds(),
            inbox_owner_address: user_address,
            inbox_name
        })

    }

    public entry fun delegate_accept_request(delegate: &signer, requester_address: address) acquires  RequestInbox, Delegate {
        let delegate_address = signer::address_of(delegate);

        assert!(exists<Delegate>(delegate_address), ENoDelegateFound);
        let delegate_data = borrow_global<Delegate>(delegate_address);
        let user_address = delegate_data.owner_address;

        assert!(exists<RequestInbox>(requester_address), EINBOX_NOT_REGISTERED);
        assert_is_pending(user_address, requester_address);
        assert_does_not_exist_in_phonebook(user_address, requester_address);

        let inbox = borrow_global_mut<RequestInbox>(user_address);

        let (exists, index) = vector::find(&inbox.pending_requests, |request|{
            let req: &Request = request;
            req.address == requester_address
        });

        assert!(exists, ERequestNotInPending);

        let request = vector::remove(&mut inbox.pending_requests, index);

        add_to_phonebook(user_address, requester_address, request.envelope, request.connection_owner);
        add_to_phonebook(requester_address, user_address, request.envelope, request.connection_owner);

        let inbox_name = get_formatted_inbox_name(requester_address, user_address);

        emit(AcceptRequestEvent {
            requester_address,
            timestamp: timestamp::now_microseconds(),
            inbox_owner_address: user_address,
            inbox_name
        })

    }

    public entry fun deny_request(user: &signer, requester_address: address) acquires RequestInbox {
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
            inbox_name: string_utils::format2(&b"{}:{}", user_address, requester_address)
        })
    }

    public entry fun delegate_deny_request(delegate: &signer, requester_address: address) acquires RequestInbox, Delegate {
        let delegate_address = signer::address_of(delegate);
        assert!(exists<Delegate>(delegate_address), ENoDelegateFound);

        let delegate_data = borrow_global<Delegate>(delegate_address);
        let user_address = delegate_data.owner_address;

        assert_has_inbox(user_address);
        assert_has_inbox(requester_address);
        assert_is_pending(user_address, requester_address);

        remove_from_pending_requests(user_address, requester_address);

        emit(RequestDeniedEvent {
            requester_address,
            inbox_owner_address: user_address,
            timestamp: timestamp::now_microseconds(),
            inbox_name: string_utils::format2(&b"{}{}", user_address, requester_address)
        })
    }

    public entry fun remove_from_phone_book(user: &signer, unwanted_address: address) acquires RequestInbox {
        let user_address = signer::address_of(user);
        assert_has_inbox(user_address);
        assert_has_inbox(unwanted_address);
        assert_is_in_inbox(user_address, unwanted_address);

        let inbox_name = get_formatted_inbox_name(user_address, unwanted_address);

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
            inbox_name
        })
    }

    public entry fun delegate_remove_from_phone_book(delegate: &signer, unwanted_address: address) acquires  RequestInbox, Delegate {
        let delegate_address = signer::address_of(delegate);

        assert!(exists<Delegate>(delegate_address), ENoDelegateFound);

        let delegate_data = borrow_global<Delegate>(delegate_address);

        let user_address = delegate_data.owner_address;

        assert_has_inbox(user_address);
        assert_has_inbox(unwanted_address);
        assert_is_in_inbox(user_address, unwanted_address);
        let inbox_name = get_formatted_inbox_name(user_address, unwanted_address);

        let inbox = borrow_global_mut<RequestInbox>(user_address);

        let (_, index) = vector::find(&inbox.phone_book, |request|{
            let req: &Request = request;
            req.address == unwanted_address
        });

        vector::remove(&mut inbox.phone_book, index);

        emit(RequestRemoveFromPhoneBookEvent {
            timestamp: timestamp::now_microseconds(),
            inbox_owner_address: user_address,
            requester_address: unwanted_address,
            inbox_name
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

    inline fun add_to_phonebook(inbox_owner: address, user_address: address, envelope: string::String, connection_owner: address) acquires  RequestInbox {
        assert_does_not_exist_in_phonebook(inbox_owner, user_address);
        let inbox = borrow_global_mut<RequestInbox>(inbox_owner);
        vector::push_back(&mut inbox.phone_book, Request {
            address: user_address,
            timestamp: timestamp::now_microseconds(),
            envelope,
            connection_owner
        })
    }

    inline fun remove_from_pending_requests(inbox_owner: address, user_address: address) acquires  RequestInbox {
        assert_is_pending(inbox_owner, user_address);
        let inbox = borrow_global_mut<RequestInbox>(inbox_owner);

        let (_, index) = vector::find(&inbox.pending_requests, |request|{
            let req: &Request = request;
            req.address == user_address
        });

        vector::remove(&mut inbox.pending_requests, index);
    }

    inline fun remove_from_phonebook(inbox_owner: address, user_address: address) acquires RequestInbox {
        assert_is_in_inbox(inbox_owner, user_address);
        let inbox = borrow_global_mut<RequestInbox>(inbox_owner);
        let(_, index) = vector::find(&inbox.phone_book, |request| {
            let req: &Request = request;
            req.address == user_address
        });

        vector::remove(&mut inbox.phone_book, index);
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

    public(friend) fun assert_is_delegate(delegate_address: address){
        assert!(exists<Delegate>(delegate_address), ENoDelegateFound);
    }

    public(friend) fun get_delegate_owner(delegate_address: address): address acquires Delegate {
        let delegate = borrow_global<Delegate>(delegate_address);
        delegate.owner_address
    }

    public(friend) fun get_public_key(user_address: address): string::String acquires RequestInbox {
        let inbox = borrow_global<RequestInbox>(user_address);
        inbox.public_key
    }

    #[view]
    public fun get_connection_owner(sender_address: address, receiver_address: address): address acquires RequestInbox {
        let inbox = borrow_global<RequestInbox>(sender_address);

        let (_, index) = vector::find(&inbox.phone_book, |request|{
            let req: &Request = request;
            req.address == receiver_address
        });

        let request = vector::borrow(&inbox.phone_book, index);

        request.connection_owner
    }

    #[view]
    public fun get_formatted_inbox_name(sender_address: address, receiver_address: address): string::String acquires RequestInbox {
        let connection_owner = get_connection_owner(sender_address, receiver_address);

        if(connection_owner == sender_address){
            return string_utils::format2(&b"{}:{}", sender_address, receiver_address)
        }else{
            return string_utils::format2(&b"{}:{}", receiver_address, sender_address)
        }
    }

    public fun is_delegate(addr: address): bool {
        return exists<Delegate>(addr)
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
    fun test_register_inbox() acquires State {

        let admin = account::create_account_for_test(@hermes);
        let user_account = account::create_account_for_test(@0x321);
        let aptos_framework = account::create_account_for_test(@0x1);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        init_module(&admin);

        register_request_inbox(&user_account, string::utf8(b""));

        let events = emitted_events<RequestInboxRegisterEvent>();
        assert!(vector::length(&events) == 1, 0);

        debug::print(&events);
    }

    #[test]
    fun test_make_conversation_request() acquires RequestInbox, State {

        let admin = account::create_account_for_test(@hermes);
        let user_account = account::create_account_for_test(@0x321);
        let second_user_account = account::create_account_for_test(@0x3261);
        let aptos_framework = account::create_account_for_test(@0x1);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        init_module(&admin);

        register_request_inbox(&user_account, string::utf8(b""));
        register_request_inbox(&second_user_account, string::utf8(b""));

        request_conversation(&second_user_account, signer::address_of(&user_account), string::utf8(b""));

        let register_events = emitted_events<RequestInboxRegisterEvent>();

        assert!(vector::length(&register_events) == 2, 0);

        let request_events = emitted_events<RequestEvent>();

        assert!(vector::length(&request_events) == 1, 1);

        debug::print(&request_events);
    }

    #[test]
    fun test_accept_conversation_request() acquires RequestInbox, State {
        let admin = account::create_account_for_test(@hermes);
        let user_account = account::create_account_for_test(@0x321);
        let second_user_account = account::create_account_for_test(@0x3261);
        let aptos_framework = account::create_account_for_test(@0x1);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        init_module(&admin);

        register_request_inbox(&user_account, string::utf8(b""));
        register_request_inbox(&second_user_account, string::utf8(b""));

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
    fun test_deny_conversation_request() acquires RequestInbox, State {
        let admin = account::create_account_for_test(@hermes);
        let user_account = account::create_account_for_test(@0x321);
        let second_user_account = account::create_account_for_test(@0x3261);
        let aptos_framework = account::create_account_for_test(@0x1);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        init_module(&admin);

        register_request_inbox(&user_account, string::utf8(b""));
        register_request_inbox(&second_user_account, string::utf8(b""));

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
    fun test_remove_from_phonebook() acquires RequestInbox, State {
        let admin = account::create_account_for_test(@hermes);
        let user_account = account::create_account_for_test(@0x321);
        let second_user_account = account::create_account_for_test(@0x3261);
        let aptos_framework = account::create_account_for_test(@0x1);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        init_module(&admin);

        register_request_inbox(&user_account, string::utf8(b""));
        register_request_inbox(&second_user_account, string::utf8(b""));

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

    #[test]
    fun test_add_delegate() acquires State, RequestInbox {
        let admin = account::create_account_for_test(@hermes);
        let user_account = account::create_account_for_test(@0x321);
        let delegate_account = account::create_account_for_test(@0x3261);
        let aptos_framework = account::create_account_for_test(@0x1);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        init_module(&admin);

        register_request_inbox(&user_account, string::utf8(b""));
        create_delegate_link_intent(&user_account, signer::address_of(&delegate_account));
        register_delegate(&delegate_account, signer::address_of(&user_account));


        let inbox_register_events = emitted_events<RequestInboxRegisterEvent>();
        assert!(vector::length(&inbox_register_events) == 1, 0);

        let delegate_register_events = emitted_events<DelegateRegisterEvent>();
        assert!(vector::length(&delegate_register_events) == 1, 1);

    }

    #[test]
    fun test_delegate_remove() acquires State, RequestInbox, Delegate {
        let admin = account::create_account_for_test(@hermes);
        let user_account = account::create_account_for_test(@0x321);
        let delegate_account = account::create_account_for_test(@0x3261);
        let aptos_framework = account::create_account_for_test(@0x1);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        init_module(&admin);

        register_request_inbox(&user_account, string::utf8(b""));
        create_delegate_link_intent(&user_account, signer::address_of(&delegate_account));
        register_delegate(&delegate_account, signer::address_of(&user_account));
        remove_delegate(&user_account, signer::address_of(&delegate_account));


        let inbox_register_events = emitted_events<RequestInboxRegisterEvent>();
        assert!(vector::length(&inbox_register_events) == 1, 0);

        let delegate_register_events = emitted_events<DelegateRegisterEvent>();
        assert!(vector::length(&delegate_register_events) == 1, 1);


    }

    #[test]
    fun test_delegate_create_conversation_request() acquires State, RequestInbox, Delegate {
        let admin = account::create_account_for_test(@hermes);
        let user_account = account::create_account_for_test(@0x321);
        let delegate_account = account::create_account_for_test(@0x3261);
        let second_account = account::create_account_for_test(@0x43);
        let second_delegate = account::create_account_for_test(@0x54);
        let aptos_framework = account::create_account_for_test(@0x1);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        init_module(&admin);

        register_request_inbox(&user_account, string::utf8(b""));
        create_delegate_link_intent(&user_account, signer::address_of(&delegate_account));
        register_delegate(&delegate_account, signer::address_of(&user_account));
        register_request_inbox(&second_account, string::utf8(b""));
        create_delegate_link_intent(&second_account, signer::address_of(&second_delegate));
        register_delegate(&second_delegate, signer::address_of(&second_account));

        delegate_request_conversation(&delegate_account, signer::address_of(&second_account), string::utf8(b""));

        let request_events = emitted_events<RequestEvent>();

        assert!(vector::length(&request_events) == 1, 0);

    }

    #[test]
    fun test_delegate_accept_request() acquires State, RequestInbox, Delegate {
        let admin = account::create_account_for_test(@hermes);
        let user_account = account::create_account_for_test(@0x321);
        let delegate_account = account::create_account_for_test(@0x3261);
        let second_account = account::create_account_for_test(@0x43);
        let second_delegate = account::create_account_for_test(@0x54);
        let aptos_framework = account::create_account_for_test(@0x1);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        init_module(&admin);

        register_request_inbox(&user_account, string::utf8(b""));
        create_delegate_link_intent(&user_account, signer::address_of(&delegate_account));
        register_delegate(&delegate_account, signer::address_of(&user_account));
        register_request_inbox(&second_account, string::utf8(b""));
        create_delegate_link_intent(&second_account, signer::address_of(&second_delegate));
        register_delegate(&second_delegate, signer::address_of(&second_account));

        delegate_request_conversation(&delegate_account, signer::address_of(&second_account), string::utf8(b""));

        let request_events = emitted_events<RequestEvent>();

        assert!(vector::length(&request_events) == 1, 0);

        delegate_accept_request(&second_delegate, signer::address_of(&user_account));

        let accepted_requests = emitted_events<AcceptRequestEvent>();

        assert!(vector::length(&accepted_requests) == 1, 1);
    }

    #[test]
    fun test_delegate_deny_request() acquires State, RequestInbox, Delegate {
        let admin = account::create_account_for_test(@hermes);
        let user_account = account::create_account_for_test(@0x321);
        let delegate_account = account::create_account_for_test(@0x3261);
        let second_account = account::create_account_for_test(@0x43);
        let second_delegate = account::create_account_for_test(@0x54);
        let aptos_framework = account::create_account_for_test(@0x1);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        init_module(&admin);

        register_request_inbox(&user_account, string::utf8(b""));
        create_delegate_link_intent(&user_account, signer::address_of(&delegate_account));
        register_delegate(&delegate_account, signer::address_of(&user_account));
        register_request_inbox(&second_account, string::utf8(b""));
        create_delegate_link_intent(&second_account, signer::address_of(&second_delegate));
        register_delegate(&second_delegate, signer::address_of(&second_account));

        delegate_request_conversation(&delegate_account, signer::address_of(&second_account), string::utf8(b""));

        delegate_deny_request(&second_delegate, signer::address_of(&user_account));

        let denied_requests = emitted_events<RequestDeniedEvent>();

        assert!(vector::length(&denied_requests) == 1, 8);
    }

}
