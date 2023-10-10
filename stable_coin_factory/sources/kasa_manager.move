module stable_coin_factory::kasa_manager {
    use std::option::{Self, Option};
    use std::vector;

    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::event;
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::package::{Self, Publisher};

    use stable_coin_factory::kasa_storage::{Self, KasaManagerStorage};
    use stable_coin_factory::stability_pool::{Self, StabilityPoolStorage};
    use stable_coin_factory::liquidation_assets_distributor::CollateralGains;
    use stable_coin_factory::sorted_kasas::{Self, SortedKasasStorage};
    use tokens::rusd_stable_coin::{Self, RUSD_STABLE_COIN, RUSDStableCoinStorage};
    use library::kasa::{is_icr_valid, get_minimum_collateral_ratio};
    // use library::utils::logger;

    friend stable_coin_factory::kasa_operations;

    const COLLATERAL_PRICE: u64 = 1800_000000000;

    // =================== Errors ===================

    const ERROR_LIST_FULL: u64 = 1;
    const ERROR_EXISTING_ITEM: u64 = 2;
    const ERROR_: u64 = 3;
    const ERROR_UNABLE_TO_REDEEM: u64 = 4;

    // =================== Storage ===================

    /// OTW for Kasa Manager
    struct KASA_MANAGER has drop {}

    /// Defines the data structure for saving the publisher
    struct KasaManagerPublisher has key {
        id: UID,
        publisher: Publisher
    }

    // =================== Events ===================

    /// Defines the event for when a Kasa is created
    struct KasaCreated has copy, drop {
        account_address: address,
        collateral_amount: u64,
        debt_amount: u64
    }

    // =================== Initializer ===================

    fun init(witness: KASA_MANAGER, ctx: &mut TxContext) {
        transfer::share_object(KasaManagerPublisher {
            id: object::new(ctx),
            publisher: package::claim<KASA_MANAGER>(witness, ctx)
        });
    }

    // =================== Entries ===================

    public(friend) fun create_kasa(
        km_publisher: &KasaManagerPublisher,
        km_storage: &mut KasaManagerStorage,
        rsc_storage: &mut RUSDStableCoinStorage,
        account_address: address,
        collateral: Coin<SUI>,
        debt_amount: u64,
        ctx: &mut TxContext
    ) { 
        // Get the collateral amount and balance from the coin object
        let collateral_amount = coin::value<SUI>(&collateral);
        let collateral_balance = coin::into_balance<SUI>(collateral);

        // Mint the rUSD to the user
        let stable_coin = rusd_stable_coin::mint(
            rsc_storage,
            get_publisher(km_publisher),
            account_address,
            debt_amount,
            ctx
        );
        let stable_coin_amount = coin::value(&stable_coin);

        // Create Kasa object
        kasa_storage::create_kasa(
            km_storage,
            account_address,
            collateral_amount,
            debt_amount
        );

        // Update the total collateral balance of the protocol
        kasa_storage::increase_total_collateral_balance(km_storage, collateral_balance);
        // Update the total debt balance of the protocol
        kasa_storage::increase_total_debt_balance(km_storage, stable_coin_amount);

        // Transfer the stable coin to the user
        transfer::public_transfer(stable_coin, account_address);

        // Emit event
        event::emit(KasaCreated {
            account_address,
            collateral_amount,
            debt_amount
        })
    }

    public(friend) fun increase_collateral(
        km_storage: &mut KasaManagerStorage,
        account_address: address,
        collateral: Coin<SUI>
    ) {
        // TODO: Where do we transfer the collateral to?
        let amount = coin::value<SUI>(&collateral);

        // Update Kasa object
        kasa_storage::increase_kasa_collateral_amount(km_storage, account_address, amount);

        // Update total collateral balance of the protocol
        kasa_storage::increase_total_collateral_balance(km_storage, coin::into_balance<SUI>(collateral));
    }
    
    public(friend) fun decrease_collateral(
        km_storage: &mut KasaManagerStorage,
        account_address: address,
        amount: u64,
        ctx: &mut TxContext
    ) {
        // Update Kasa object
        kasa_storage::decrease_kasa_collateral_amount(km_storage, account_address, amount);

        // Update total collateral balance of the protocol
        let collateral = kasa_storage::decrease_total_collateral_balance(km_storage, amount, ctx);

        // Transfer the collateral back to the user
        transfer::public_transfer(collateral, account_address);
    }

    public(friend) fun increase_debt(
        km_publisher: &KasaManagerPublisher,
        km_storage: &mut KasaManagerStorage,
        rsc_storage: &mut RUSDStableCoinStorage,
        account_address: address,
        amount: u64,
        ctx: &mut TxContext
    ) {
        // Mint the rUSD to the user
        let rusd = rusd_stable_coin::mint(
            rsc_storage,
            get_publisher(km_publisher),
            account_address,
            amount,
            ctx
        );
        transfer::public_transfer(rusd, account_address);

        // Update the Kasa object
        kasa_storage::increase_kasa_debt_amount(km_storage, account_address, amount);

        // Update the total debt balance of the protocol
        kasa_storage::increase_total_debt_balance(km_storage, amount);
    }

    public(friend) fun decrease_debt(
        km_publisher: &KasaManagerPublisher,
        km_storage: &mut KasaManagerStorage,
        rsc_storage: &mut RUSDStableCoinStorage,
        account_address: address,
        debt_coin: Coin<RUSD_STABLE_COIN>
    ) {
        let amount = coin::value(&debt_coin);

        // Update the Kasa object
        kasa_storage::decrease_kasa_debt_amount(km_storage, account_address, amount);

        // Update the total debt balance of the protocol
        kasa_storage::decrease_total_debt_balance(km_storage, amount);

        // Burn the rUSD from the user
        rusd_stable_coin::burn(
            rsc_storage,
            get_publisher(km_publisher),
            account_address,
            debt_coin
        );
    }
    
    entry public fun liquidate_single(
        km_publisher: &KasaManagerPublisher,
        km_storage: &mut KasaManagerStorage,
        sp_storage: &mut StabilityPoolStorage,
        collateral_gains: &mut CollateralGains,
        rsc_storage: &mut RUSDStableCoinStorage,
        account_address: address,
        ctx: &mut TxContext
    ) {
        let account_addresses = vector::empty<address>();
        vector::push_back(&mut account_addresses, account_address);

        liquidate_kasas(
            km_publisher,
            km_storage,
            sp_storage,
            collateral_gains,
            rsc_storage,
            account_addresses,
            ctx
        );
    }

    entry public fun liquidate_batch(
        km_publisher: &KasaManagerPublisher,
        km_storage: &mut KasaManagerStorage,
        sp_storage: &mut StabilityPoolStorage,
        collateral_gains: &mut CollateralGains,
        rsc_storage: &mut RUSDStableCoinStorage,
        account_addresses: vector<address>,
        ctx: &mut TxContext
    ) {
        liquidate_kasas(
            km_publisher,
            km_storage,
            sp_storage,
            collateral_gains,
            rsc_storage,
            account_addresses,
            ctx
        );
    }

    /// Redeems RUSD stable coins for collateral
    /// 
    /// # Arguments
    /// 
    /// * `kasa_manager_storage` - the KasaManagerStorage object
    /// * `rusd_stable_coin_storage` - the RUSDStableCoinStorage object
    /// * `amount` - the amount of RUSD stable coins to redeem
    entry public fun redeem(
        km_publisher: &KasaManagerPublisher,
        km_storage: &mut KasaManagerStorage,
        sk_storage: &mut SortedKasasStorage,
        rsc_storage: &mut RUSDStableCoinStorage,
        stable_coin: Coin<RUSD_STABLE_COIN>,
        first_redemption_hint: Option<address>,
        upper_partial_redemption_hint: Option<address>,
        lower_partial_redemption_hint: Option<address>,
        partial_redemption_hint_nicr: u256,
        ctx: &mut TxContext
    ) {
        let stable_coin_amount = coin::value(&stable_coin);

        // TODO: Disable this method for 14 days after release
        // TODO: IF TCR < 110% throw error
        // TODO: Do not redeem Kasas with ICR < MCR => ICR must be >= to 110%
        // TODO: Check the actual code and fork the assert statements

        let (_, total_debt_amount) = kasa_storage::get_total_balances(km_storage);

        let (_, sender_debt_amount) = kasa_storage::get_kasa_amounts(
            km_storage,
            tx_context::sender(ctx)
        );
        let user_stable_coin_balance = rusd_stable_coin::get_balance(rsc_storage, tx_context::sender(ctx));
        assert!(user_stable_coin_balance <= stable_coin_amount, ERROR_); // FIXME: Find a better error code

        let remaining_stable_coin_amount = coin::value(&stable_coin);
        let total_debt_to_decrease = coin::zero<RUSD_STABLE_COIN>(ctx);
        let total_collateral_to_send = coin::zero<SUI>(ctx);
        let current_kasa_owner: Option<address>;

        if (check_first_redemption_hint(sk_storage, first_redemption_hint, 0)) { // FIXME: Change the collateral price
            current_kasa_owner = first_redemption_hint;
        } else {
            current_kasa_owner = sorted_kasas::get_last(sk_storage);
            // Find the first trove with ICR >= MCR
            while (
                option::is_some(&current_kasa_owner) &&
                kasa_storage::get_collateral_ratio(
                    km_storage,
                    option::destroy_some(current_kasa_owner),
                    COLLATERAL_PRICE
                ) < get_minimum_collateral_ratio()
            ) {
                current_kasa_owner = sorted_kasas::get_prev(
                    sk_storage,
                    option::destroy_some(current_kasa_owner)
                );
            };
        };

        // TODO: Implement max iterations?
        while (option::is_some(&current_kasa_owner) && remaining_stable_coin_amount > 0) {
            // max_iterations = max_iterations - 1;
            let next_kasa_owner = sorted_kasas::get_prev(
                sk_storage,
                option::destroy_some(current_kasa_owner)
            );

            // TODO: Apply pending rewards here
            // Rewards include the redistribution of kasas

            // TODO: Remove collateral from kasa method
            // We will get the amount of collateral and debt to decrease
            let redemption_collateral_amount = coin::zero<SUI>(ctx); // FIXME: This will come from the redemption method
            let redemption_debt_amount = coin::zero<RUSD_STABLE_COIN>(ctx); // FIXME: Same as above

            remaining_stable_coin_amount = remaining_stable_coin_amount - coin::value(&redemption_debt_amount);
            current_kasa_owner = next_kasa_owner;

            coin::join(&mut total_collateral_to_send, redemption_collateral_amount);
            coin::join(&mut total_debt_to_decrease, redemption_debt_amount);
        };

        assert!(coin::value(&total_collateral_to_send) > 0, ERROR_UNABLE_TO_REDEEM);

        // TODO: Calculate the fee
        // Extract it from the total collateral amount

        // Decrease the total debt balance of the protocol
        kasa_storage::decrease_total_debt_balance(km_storage, coin::value(&total_debt_to_decrease));
        // Burn the rUSD tokens
        rusd_stable_coin::burn(
            rsc_storage,
            get_publisher(km_publisher),
            tx_context::sender(ctx), // FIXME: This is incorrect
            stable_coin
        );
        rusd_stable_coin::burn(
            rsc_storage,
            get_publisher(km_publisher),
            tx_context::sender(ctx), // FIXME: This is incorrect
            total_debt_to_decrease
        );
        // Send the collateral to the sender
        transfer::public_transfer(
            total_collateral_to_send,
            tx_context::sender(ctx)
        );
    }

    // =================== Helpers ===================

    fun liquidate_kasas(
        km_publisher: &KasaManagerPublisher,
        km_storage: &mut KasaManagerStorage,
        sp_storage: &mut StabilityPoolStorage,
        collateral_gains: &mut CollateralGains,
        rsc_storage: &mut RUSDStableCoinStorage,
        account_addresses: vector<address>,
        ctx: &mut TxContext
    ) {
        while (!vector::is_empty(&account_addresses)) {
            let account_address = vector::pop_back(&mut account_addresses);

            let (kasa_collateral_amount, kasa_debt_amount) = kasa_storage::get_kasa_amounts(km_storage, account_address);

            // If the ICR is valid, return
            if (is_icr_valid(false, kasa_collateral_amount, kasa_debt_amount, 1600_000000000)) return;

            // Kasa to be liquidated
            let kasa = kasa_storage::remove_kasa(km_storage, account_address);

            // Get the total stake amount from the stability pool
            let stability_pool_stake_amount = stability_pool::get_total_stake_amount(sp_storage);

            // If the stability pool has enough stake amount to cover the debt amount
            if (
                stability_pool_stake_amount != 0 &&
                stability_pool_stake_amount >= kasa_debt_amount
            ) {
                // Remove collateral from the collateral balance
                let collateral = kasa_storage::decrease_total_collateral_balance(km_storage, kasa_collateral_amount, ctx);

                // Decrease the stability pool balance
                let stable_coin = stability_pool::liquidation(
                    sp_storage,
                    collateral_gains,
                    collateral,
                    kasa_debt_amount,
                    ctx
                );
                // Burn the stable coin
                rusd_stable_coin::burn(
                    rsc_storage,
                    get_publisher(km_publisher),
                    account_address,
                    stable_coin
                );

                // Decrease the debt balance of the protocol
                kasa_storage::decrease_total_debt_balance(km_storage, kasa_debt_amount);
            };
        };

        vector::destroy_empty(account_addresses);
    }

    fun check_first_redemption_hint(
        sorted_kasas_storage: &mut SortedKasasStorage,
        hint: Option<address>,
        collateral_price: u64,
    ): bool {
        // TODO: Implement this method
        false
    }
    
    public fun get_publisher(storage: &KasaManagerPublisher): &Publisher {
        &storage.publisher
    }

    public fun get_publisher_id(publisher: &KasaManagerPublisher): ID {
        object::id(&publisher.publisher)
    }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(KASA_MANAGER {}, ctx);
    }
}