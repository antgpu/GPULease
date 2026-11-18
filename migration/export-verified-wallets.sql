SELECT json_agg(row_to_json(wallet_row) ORDER BY wallet_row.user_id, wallet_row.linked_at)
FROM (
    SELECT
        user_id,
        wallet_verifier_id::text AS wallet_verifier_id,
        lower(address) AS address,
        linked_at
    FROM launchpad.verified_wallets
) AS wallet_row;
