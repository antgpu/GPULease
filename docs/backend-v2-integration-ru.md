# Интеграция backend с account-ID контрактами GPULease V2

## Модель данных

V2 не использует EVM-адрес как владельца баланса. Канонический ключ — `bytes32
accountId`, вычисленный из уже существующего `users.wallet_verifier_id`:

```go
func AccountID(walletVerifierID string) common.Hash {
    canonical := strings.ToLower(strings.TrimSpace(walletVerifierID))
    return crypto.Keccak256Hash([]byte(canonical))
}
```

UUID обязан быть приведен к lowercase до хеширования. Email, username и числовой
`users.id` в блокчейн не отправляются.

Связь выглядит так:

```text
users.id
  -> users.wallet_verifier_id
    -> keccak256(lowercase UUID) = accountId
      -> GPULeaseWalletV2.balances(accountId)
      -> GPULeaseWalletV2.bonusBalances(accountId)
      -> GPULeaseWalletV2.walletOf(accountId) (может быть zero address)
```

## Контракты и ABI

Деплой Base mainnet (`chainId=8453`):

| Контракт | Адрес |
|---|---|
| GPULeaseWalletV2 | `0x68300FD5580DD4246fA158Cc390383b01B21cB80` |
| GPULeaseV2 | `0x82Fbbf1B587e322Ffab55B8BA0356ad93528467d` |
| GPULeaseReferralV2 | `0x732Dc19CB5c518FC1822C1acDC5327E40cB9BED1` |
| LLMFundraisingFactoryV2 | `0x3F81933E75f9f4Cc6C170a67B7d141d9B9A6DB8e` |
| LLMFundraisingV2 implementation | `0x95292150a8F4ba3f11B3A5A123B492bfD4cE2f3E` |

Машиночитаемые адреса находятся в `deployments/base-v2.json`. Проверка всей
on-chain конфигурации:

```bash
npm run check:base:v2
```

ABI генерируются:

```bash
npm run artifacts:abi
```

Нужные файлы:

- `artifacts/abi/GPULeaseWalletV2.abi`
- `artifacts/abi/GPULeaseV2.abi`
- `artifacts/abi/GPULeaseReferralV2.abi`
- `artifacts/abi/LLMFundraisingFactoryV2.abi`
- `artifacts/abi/LLMFundraisingV2.abi`

Для Go bindings:

```bash
abigen --abi artifacts/abi/GPULeaseWalletV2.abi \
  --pkg gpuleasev2 --type GPULeaseWalletV2 \
  --out internal/blockchain/gpuleasev2/wallet.go

abigen --abi artifacts/abi/GPULeaseV2.abi \
  --pkg gpuleasev2 --type GPULeaseV2 \
  --out internal/blockchain/gpuleasev2/lease.go

abigen --abi artifacts/abi/GPULeaseReferralV2.abi \
  --pkg gpuleasev2 --type GPULeaseReferralV2 \
  --out internal/blockchain/gpuleasev2/referral.go
```

## Изменения БД

Legacy-таблицы не удалять до завершения сверки. Добавить отдельное V2-состояние:

```sql
CREATE TABLE launchpad.blockchain_accounts (
    user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    account_id TEXT NOT NULL UNIQUE,
    active_wallet_address TEXT,
    wallet_bound_at TIMESTAMPTZ,
    wallet_bind_tx TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX blockchain_accounts_active_wallet_uidx
ON launchpad.blockchain_accounts (lower(active_wallet_address))
WHERE active_wallet_address IS NOT NULL;

CREATE TABLE launchpad.account_chain_state (
    account_id TEXT PRIMARY KEY,
    cash_balance_wei TEXT NOT NULL DEFAULT '0',
    bonus_balance_wei TEXT NOT NULL DEFAULT '0',
    spendable_balance_wei TEXT NOT NULL DEFAULT '0',
    frozen_balance_wei TEXT NOT NULL DEFAULT '0',
    bind_nonce_wei TEXT NOT NULL DEFAULT '0',
    withdraw_nonce_wei TEXT NOT NULL DEFAULT '0',
    last_chain_sync_at TIMESTAMPTZ,
    last_chain_error TEXT NOT NULL DEFAULT '',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

Готовая идемпотентная миграция: `migration/backend-v2-schema.sql`.

При создании/чтении пользователя backend должен детерминированно вычислять
`account_id`. Создание on-chain записи не требуется: mapping начинает существовать
при первом deposit, bonus, settlement или bind.

## Листинг машины без кошелька

Проверку `hasVerifiedWallet()` перед enrollment/listing удалить. Машина уже
связана с `users.id` через `launchpad.machines_link`; backend получает
`wallet_verifier_id`, вычисляет `providerId` и сохраняет его вместе с листингом.

Отсутствие `walletOf(providerId)` не блокирует listing или settlement. Оно
блокирует только withdrawal.

Если backend создаёт fundraising campaign за пользователя без кошелька, он
оплачивает gas и вызывает owner-only
`LLMFundraisingFactoryV2.createCampaignFor(creatorId, campaignOwner, ...)`.
Средства успешной кампании попадут в `balances(creatorId)`. Публичный
`createCampaign` доступен только кошельку, уже привязанному к указанному ID.

## Запуск аренды

Сигнатура V2:

```solidity
startLease(
    uint256 startTimestamp,
    uint256 duration,
    uint256 storagePricePerSecond,
    uint256 computePricePerSecond,
    bytes32 providerId,
    bytes32 userId
)
```

Backend больше не выбирает verified wallet как идентификатор provider/user.
Платежный источник арендатора — всегда его `accountId`. Проверка средств:

```solidity
GPULeaseWalletV2.spendableBalance(userId)
```

Если пополнение пришло от карты, campaign или platform treasury, payer делает
approve USDC и вызывает:

```solidity
depositFor(userId, amount)
```

## Gasless-привязка кошелька

Рекомендуемый поток:

1. Пользователь авторизован обычной web-сессией.
2. Backend читает `bindNonces(accountId)` и формирует EIP-712 payload.
3. Пользователь подписывает payload подключаемым кошельком без транзакции.
4. Registrar backend подписывает тот же payload.
5. Relayer backend вызывает `bindWalletWithSignatures` и платит gas.
6. После `WalletBound` backend обновляет `blockchain_accounts`.

Domain:

```json
{
  "name": "GPULeaseWalletV2",
  "version": "1",
  "chainId": 8453,
  "verifyingContract": "<GPULeaseWalletV2>"
}
```

Type:

```json
{
  "BindWallet": [
    {"name":"accountId","type":"bytes32"},
    {"name":"wallet","type":"address"},
    {"name":"nonce","type":"uint256"},
    {"name":"deadline","type":"uint256"}
  ]
}
```

`deadline` рекомендуется ограничить 10 минутами. Нельзя принимать accountId из
запроса клиента: backend вычисляет его только из авторизованного пользователя.

Упрощенный вариант — backend проверяет EIP-191/SIWE подпись off-chain и сам
вызывает registrar-only `bindWallet(accountId, wallet)`. Он также gasless для
пользователя, но доказательство владения кошельком не проверяется контрактом.

## Gasless-вывод

Backend читает `withdrawNonces(accountId)`. Пользователь подписывает:

```json
{
  "Withdraw": [
    {"name":"accountId","type":"bytes32"},
    {"name":"amount","type":"uint256"},
    {"name":"nonce","type":"uint256"},
    {"name":"deadline","type":"uint256"}
  ]
}
```

Relayer вызывает:

```solidity
withdrawWithSignature(accountId, amount, deadline, signature)
```

Контракт всегда отправляет USDC в текущий `walletOf(accountId)`. Relayer или
backend не могут подменить recipient. Повтор подписи блокируется nonce.

## Смена и восстановление кошелька

Обычная смена использует новый gasless bind. Старый wallet немедленно удаляется
из `accountOfWallet`. Для восстановления потерянного кошелька backend должен
применять усиленную проверку аккаунта и собственную задержку/уведомление до
вызова registrar-only `bindWallet`.

Если при миграции адрес не удалось связать с пользователем, баланс помещается во
временный ID:

```text
keccak256("antgpu:legacy-wallet:" + lowercase(address))
```

После подтверждения личности registrar вызывает:

```solidity
mergeAccount(legacyId, canonicalAccountId)
```

Cash, bonus и при необходимости wallet binding переходят без движения USDC.

## Event sync

Индексировать минимум:

- `Deposit(accountId, payer, amount)`
- `Withdraw(accountId, wallet, relayer, amount)`
- `WalletBound` / `WalletUnbound` / `AccountMerged`
- `LeaseBalanceDebited` / `LeaseBalanceRefunded`
- `LeaseStarted` / `LeaseSettled` / `LeaseCompleted`
- `BonusGranted` / `BonusRevoked`

После события обновлять состояние чтением view-функций на подтвержденном блоке,
а не вычислять итоговый баланс только из event delta.

## Точки изменения в текущем backend/frontend

В `launchpad_backend` нельзя ограничиться заменой адресов: generated Go types V1
содержат `common.Address`, тогда как V2 принимает `bytes32` (`common.Hash`).

1. Сгенерировать отдельный пакет bindings, например
   `lib/contracts/gpuleasev2`, из пяти V2 ABI. Не перезаписывать V1 package:
   он нужен для read-only истории старых rents.
2. В `internal/payment/service.go` заменить активные поля contracts и
   `UserBalance(address)` на account-ID варианты. Источник account ID — только
   `WalletVerifierID(userID)` + канонический helper, не request body.
3. В `internal/payment/lifecycle.go:submitStartLease` и
   `internal/payment/service.go:StartLease/FindActiveLease` заменить строки
   provider/user wallet на `common.Hash` providerId/userId. Событие
   `LeaseStarted` тоже индексируется по ID.
4. `fetchWalletChainState`, `RefreshKnownWalletChainStates`,
   `leaseRelatedWalletAddresses` и event sync перевести с address-keyed таблицы
   на `account_chain_state`; адрес читать отдельно через `walletOf(accountId)`.
5. Старый verifier event sync оставить только для legacy-аудита. Новый bind
   строится вокруг EIP-712 `WalletBound`, nonce и authenticated user session.
6. В campaign service использовать `LLMFundraisingFactoryV2` и
   `creatorAccountId`; proceeds больше не ищутся по campaign owner address.
7. Во frontend удалить wallet-gate листинга в
   `src/app/components/machines.tsx` и
   `src/app/components/enrollment-token-modal.tsx`. Wallet UI оставить для
   bind/withdraw, а не как условие создания машины.

На время перехода V1 bindings и старый адрес остаются только для чтения уже
записанной истории. Новые rents нельзя одновременно писать в V1 и V2.

## Путь пользователя без кошелька

1. Пользователь создаёт листинг; backend вычисляет `providerId` из его
   `wallet_verifier_id`. On-chain транзакции от пользователя нет.
2. Арендатор пополняет свой `userId`; backend-relayer запускает lease и платит
   gas. Выплаты начисляются в `balances(providerId)`, даже если
   `walletOf(providerId) == address(0)`.
3. Backend показывает provider баланс чтением по ID. Вывод до bind недоступен,
   но листинг, аренда и settlement продолжают работать.
4. Когда пользователь подключает кошелёк, он подписывает EIP-712 bind message.
   Backend подписывает registrar part и отправляет транзакцию за свой gas.
5. После `WalletBound` пользователь подписывает withdrawal intent; relayer
   отправляет его, а контракт переводит USDC только в связанный кошелёк.

## Cutover

1. Включить maintenance для deposit/rent/listing/withdraw.
2. Дождаться отсутствия активных V1 leases.
3. Снять новый V1 snapshot и добиться полного равенства liabilities с USDC.
4. Задеплоить V2 и проверить owner/registrar/manager/operator.
5. Экспортировать authoritative `verified_wallets` из production DB.
6. Выполнить migration script.
7. Переключить backend contract addresses и bindings на V2.
8. Запустить initial account sync, затем включить API и frontend.
9. Оставить V1 адреса и snapshot read-only для аудита.

Нельзя мигрировать деньги при работающем старом deposit/rent flow: новый депозит
между snapshot и переключением нарушит сверку.

Экспорт выполняется read-only запросом из
`migration/export-verified-wallets.sql`; результат сохранить как
`migration/verified-wallets.json`. Этот файл содержит связь пользователей с
кошельками и не должен коммититься или передаваться наружу.

Команды подготовки и переноса:

```bash
psql "$DATABASE_URL" -At -f migration/export-verified-wallets.sql \
  > migration/verified-wallets.json

# Только проверка; транзакций не отправляет.
npm run migrate:base:v1-v2

# Запускать строго внутри maintenance-окна после проверки dry-run плана.
EXECUTE_MIGRATION=YES npm run migrate:base:v1-v2

# После выполнения обязан показать tokenBalance == accountedBalance.
npm run check:base:v2
```

До включения backend заменить bindings и адреса, затем назначить его relayer:

- `GPULeaseWalletV2.setRegistrar(<backend relayer>)` — gasless bind/recovery;
- `GPULeaseV2.setSettlementOperator(<backend relayer>)` — daily settlement;
- owner `GPULeaseV2` выполняет lifecycle-транзакции `start/pause/resume/complete`;
- owner `LLMFundraisingFactoryV2` вызывает gasless `createCampaignFor`.

Если lifecycle и campaign relayer должны работать отдельным ключом, ownership
соответствующего контракта переводится только после тестовой транзакции и
проверки нового адреса. `registrar`, `owner` и `settlementOperator` не должны
храниться во frontend.
