BEGIN;

CREATE TABLE IF NOT EXISTS launchpad.blockchain_accounts (
    user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    account_id TEXT NOT NULL UNIQUE,
    active_wallet_address TEXT,
    wallet_bound_at TIMESTAMPTZ,
    wallet_bind_tx TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT blockchain_accounts_account_id_format
        CHECK (account_id ~ '^0x[0-9a-f]{64}$'),
    CONSTRAINT blockchain_accounts_wallet_format
        CHECK (
            active_wallet_address IS NULL OR
            active_wallet_address ~ '^0x[0-9a-f]{40}$'
        )
);

CREATE UNIQUE INDEX IF NOT EXISTS blockchain_accounts_active_wallet_uidx
ON launchpad.blockchain_accounts (lower(active_wallet_address))
WHERE active_wallet_address IS NOT NULL;

CREATE TABLE IF NOT EXISTS launchpad.account_chain_state (
    account_id TEXT PRIMARY KEY,
    cash_balance_wei TEXT NOT NULL DEFAULT '0',
    bonus_balance_wei TEXT NOT NULL DEFAULT '0',
    spendable_balance_wei TEXT NOT NULL DEFAULT '0',
    frozen_balance_wei TEXT NOT NULL DEFAULT '0',
    bind_nonce_wei TEXT NOT NULL DEFAULT '0',
    withdraw_nonce_wei TEXT NOT NULL DEFAULT '0',
    last_chain_sync_at TIMESTAMPTZ,
    last_chain_error TEXT NOT NULL DEFAULT '',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT account_chain_state_account_id_format
        CHECK (account_id ~ '^0x[0-9a-f]{64}$')
);

COMMIT;
