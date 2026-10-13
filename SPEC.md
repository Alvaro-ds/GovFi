# GovFi Protocol — Especificación Técnica

**Stack:** Solidity ^0.8.20 · Foundry · OpenZeppelin 5.x  
**Autor:** Arquitecto técnico GovFi  
**Fecha:** 2026-10-13

---

## Convenciones globales del proyecto

- Imports sin llaves: `import "@openzeppelin/contracts/access/Ownable.sol";`
- Literales numéricos sin guión bajo: `10000`, nunca `10_000`
- Validaciones con `require(condition, "Reason")`, nunca `error Foo()` / `revert Foo()`
- Sin bloques `unchecked`
- Tests: un archivo `.t.sol` por contrato fuente, todos heredan directamente de `Test`. Sin subdirectorios en `test/`
- Actores de test: `vm.addr(N)` + `vm.label`; nunca `makeAddr` ni literales
- Pranks: siempre `vm.startPrank` / `vm.stopPrank`, nunca `vm.prank`

---

## Flujo del protocolo (visión global)

```
Usuario deposita TokenA + TokenB
        │
        ▼
  LiquidityPool ──── acuña LP tokens ──► Usuario
        │
        │ 20% del swap fee
        ▼
  DAOTreasury
        │
        │ (solo mediante propuesta aprobada)
        ▼
      DAO ◄──── GovernanceToken (votos)
        │
        │ parámetros gobernables
        ▼
  YieldFarmingPool ── distribuye GovernanceToken ──► Stakers de LP
```

**Ciclo de gobernanza:** propuesta (proposalThreshold mínimo) → votación 3 días → timelock 1 día → ejecución.

---

## Orden de despliegue

El orden importa porque DAO y DAOTreasury se referencian mutuamente:

```
1. Deploy GovernanceToken(maxSupply, name, symbol)
2. Deploy DAOTreasury(address(0))        ← placeholder, setDAO se llama en paso 4
3. Deploy LiquidityPool(tokenA, tokenB, treasury)
4. Deploy YieldFarmingPool(lpToken, govToken, rewardRate)
5. Deploy DAO(govToken, treasury, yieldPool, liquidityPool, votingPeriod, timelockDelay, quorumBps, proposalThreshold)
6. treasury.setDAO(address(dao))         ← conecta la referencia
7. govToken.grantMinterRole(address(yieldFarmingPool))
8. (Opcional) govToken owner renuncia al ownership
```

---

## src/tokens/GovernanceToken.sol

### Propósito
Token ERC20 con capacidades de gobernanza on-chain. Es la unidad de poder de voto del protocolo. Solo el `YieldFarmingPool` puede acuñar nuevos tokens (rol `MINTER_ROLE`). Tiene un supply máximo configurado en deploy.

### Herencias OpenZeppelin

| Contrato OZ | Por qué |
|---|---|
| `ERC20` | Funcionalidad base de token fungible |
| `ERC20Votes` | Snapshots de voting power por bloque (`getPastVotes`). Mitiga ataques de flash loan en gobernanza |
| `ERC20Permit` | Permite `permit()` (EIP-2612): aprobaciones gasless con firma off-chain |
| `AccessControl` | Gestión del rol `MINTER_ROLE` para controlar quién puede acuñar |
| `Ownable` | Owner inicial que configura el ecosistema y luego puede renunciar |

### Variables de estado

| Nombre | Tipo | Visibilidad | Descripción |
|---|---|---|---|
| `MINTER_ROLE` | `bytes32` | `public constant` | Hash del rol de acuñador: `keccak256("MINTER_ROLE")` |
| `maxSupply_` | `uint256` | `private` | Supply máximo absoluto. Establecido en el constructor, inmutable |

### Eventos

| Nombre | Parámetros | Cuándo se emite |
|---|---|---|
| `MinterRoleGranted` | `address indexed minter` | Cuando se otorga `MINTER_ROLE` a una dirección |
| `MinterRoleRevoked` | `address indexed minter` | Cuando se revoca `MINTER_ROLE` |
| `MaxSupplyReached` | `uint256 currentSupply` | Cuando un intento de mint alcanza exactamente el tope (informativo) |

> Los eventos de grant/revoke de roles estándar de AccessControl (`RoleGranted`, `RoleRevoked`) ya los emite OZ; estos son adicionales para mayor trazabilidad.

### Funciones

#### `constructor(uint256 maxSupply, string memory name, string memory symbol, address initialOwner)`
- Visibilidad: —
- Inicializa ERC20, ERC20Permit, AccessControl, Ownable con `initialOwner`
- Establece `maxSupply_`
- Otorga `DEFAULT_ADMIN_ROLE` y `MINTER_ROLE` a `initialOwner` temporalmente (el owner los reasignará durante el setup del ecosistema)
- Restricciones: `maxSupply > 0`

#### `mint(address to, uint256 amount) external`
- Visibilidad: `external`
- Acuña `amount` tokens hacia `to`
- Restricciones de acceso: `onlyRole(MINTER_ROLE)`
- Restricciones de lógica: `totalSupply() + amount <= maxSupply_`
- Llama a `_update` (internamente via `_mint`) que actualiza los checkpoints de `ERC20Votes`

#### `maxSupply() external view returns (uint256)`
- Devuelve `maxSupply_`

#### `burn(uint256 amount) external`
- Visibilidad: `external`
- Quema `amount` tokens del `msg.sender`
- No requiere rol especial; cualquier holder puede quemar los suyos

### Relaciones con otros contratos
- **YieldFarmingPool** es el único titular de `MINTER_ROLE` en producción
- **DAO** lee `getPastVotes(voter, proposalSnapshotBlock)` para calcular poder de voto

### Consideraciones de seguridad
- `ERC20Votes` usa snapshots por bloque: el poder de voto en una propuesta se fija en el bloque de creación de la propuesta (`clock()`), haciendo imposible el ataque de flash loan de gobernanza
- Si se usa `delegateTo` de OZ (ERC20Votes nativo), hay que llamar a `delegate(self)` para que los propios tokens cuenten como votos; documentarlo en el README
- El rol `DEFAULT_ADMIN_ROLE` debe transferirse a la propia DAO o revocarse una vez el ecosistema esté configurado
- `maxSupply_` como invariante duro: si `mint` lo superara, cualquier integrador que confíe en ese tope quedaría expuesto a inflación ilimitada

---

## src/core/LiquidityPool.sol

### Propósito
Pool de liquidez AMM simplificado (x·y=k) para el par TokenA/TokenB. El propio contrato es el token LP (hereda ERC20). Cobra un fee configurable por swap; distribuye el 80% a los LPs (implícitamente, via la fórmula k) y transfiere el 20% directamente al `DAOTreasury` en cada swap.

### Herencias OpenZeppelin

| Contrato OZ | Por qué |
|---|---|
| `ERC20` | El contrato mismo es el LP token; acuña/quema shares proporcionales a liquidez |
| `ReentrancyGuard` | Protección de todas las funciones que mueven fondos |
| `Ownable` | Owner inicial = deployer; luego la DAO toma control via propuestas |

> No hereda de ningún AMM externo. Implementación propia simplificada, intencionalmente didáctica.

### Variables de estado

| Nombre | Tipo | Visibilidad | Descripción |
|---|---|---|---|
| `tokenA` | `address` | `public immutable` | Dirección del token A del par |
| `tokenB` | `address` | `public immutable` | Dirección del token B del par |
| `treasury` | `address` | `public` | Dirección del DAOTreasury que recibe el 20% del fee |
| `dao` | `address` | `public` | Dirección del DAO; único que puede cambiar `feeBps` |
| `reserveA` | `uint256` | `public` | Reserva contable de tokenA (no usar `balanceOf` para evitar donación forzada) |
| `reserveB` | `uint256` | `public` | Reserva contable de tokenB |
| `feeBps` | `uint256` | `public` | Fee de swap en basis points. Default: `30` (0.30%). Rango válido: 1–1000 |
| `FEE_DENOMINATOR` | `uint256` | `public constant` | `10000` — denominador para cálculo de basis points |
| `TREASURY_FEE_SHARE` | `uint256` | `public constant` | `20` — porcentaje del fee que va al treasury (en %) |
| `MINIMUM_LIQUIDITY` | `uint256` | `private constant` | `1000` — liquidez mínima quemada en el primer depósito para evitar inflation attack |

### Eventos

| Nombre | Parámetros | Cuándo se emite |
|---|---|---|
| `LiquidityAdded` | `address indexed provider, uint256 amountA, uint256 amountB, uint256 lpMinted` | En `addLiquidity` |
| `LiquidityRemoved` | `address indexed provider, uint256 amountA, uint256 amountB, uint256 lpBurned` | En `removeLiquidity` |
| `Swap` | `address indexed trader, address indexed tokenIn, uint256 amountIn, uint256 amountOut, uint256 feeAmount` | En `swap` |
| `FeeUpdated` | `uint256 oldFeeBps, uint256 newFeeBps` | En `setFeeBps` |
| `TreasuryUpdated` | `address indexed oldTreasury, address indexed newTreasury` | En `setTreasury` |
| `DAOSet` | `address indexed dao` | En `setDAO` |

### Errores (via `require`)

| Condición | Mensaje |
|---|---|
| Reserva A o B es cero al calcular precio | `"ZeroReserve"` |
| Monto de salida calculado es cero | `"InsufficientOutputAmount"` |
| Slippage superado (amountOut < minAmountOut) | `"SlippageExceeded"` |
| LP tokens a quemar es cero | `"ZeroAmount"` |
| Primer depósito produce menos de MINIMUM_LIQUIDITY shares | `"InsufficientInitialLiquidity"` |
| Fee fuera de rango | `"InvalidFee"` |
| Llamante no es la DAO | `"OnlyDAO"` |
| Dirección cero en parámetros críticos | `"ZeroAddress"` |
| Deadline de transacción vencido | `"Expired"` |

### Funciones

#### `constructor(address tokenA_, address tokenB_, address treasury_, address initialOwner)`
- Establece `tokenA`, `tokenB`, `treasury`, `feeBps = 30`
- Inicializa ERC20 con nombre "GovFi LP Token" y símbolo "GFI-LP"
- Restricciones: ninguna dirección puede ser `address(0)`; `tokenA_ != tokenB_`

#### `setDAO(address dao_) external onlyOwner`
- Establece la dirección del DAO que podrá gobernar el pool
- Solo puede llamarse una vez (o restringido al owner)
- Emite `DAOSet`

#### `addLiquidity(uint256 amountADesired, uint256 amountBDesired, uint256 amountAMin, uint256 amountBMin, address to, uint256 deadline) external nonReentrant returns (uint256 lpMinted)`
- Si las reservas están vacías: deposita ambos montos tal cual, quema `MINIMUM_LIQUIDITY` LP tokens hacia `address(1)` (previene inflation attack), acuña el resto a `to`
- Si ya hay reservas: calcula la cantidad óptima de B para mantener la ratio A/B, verifica que ambos montos estén por encima de los mínimos (`amountAMin`, `amountBMin`)
- LP minted proporcional a `min(amountA/reserveA, amountB/reserveB) * totalSupply`
- Transfiere los tokens al contrato, actualiza reservas, acuña LP
- Emite `LiquidityAdded`

#### `removeLiquidity(uint256 lpAmount, uint256 amountAMin, uint256 amountBMin, address to, uint256 deadline) external nonReentrant returns (uint256 amountA, uint256 amountB)`
- Quema `lpAmount` LP tokens del `msg.sender`
- Devuelve `amountA = lpAmount * reserveA / totalSupply` y análogo para B
- Verifica que ambos montos superen los mínimos (slippage)
- Transfiere tokens al `to`, actualiza reservas
- Emite `LiquidityRemoved`

#### `swap(address tokenIn, uint256 amountIn, uint256 minAmountOut, address to, uint256 deadline) external nonReentrant returns (uint256 amountOut)`
- Valida que `tokenIn` sea `tokenA` o `tokenB`
- Calcula fee total: `feeAmount = amountIn * feeBps / FEE_DENOMINATOR`
- Calcula fee para treasury: `treasuryFee = feeAmount * TREASURY_FEE_SHARE / 100`
- El resto del fee (`feeAmount - treasuryFee`) queda en el pool, beneficiando a los LPs
- Aplica fórmula x·y=k sobre el monto neto (amountIn - feeAmount)
- Verifica slippage: `amountOut >= minAmountOut`
- CEI: actualiza reservas **antes** de transferir tokens de salida
- Transfiere `treasuryFee` al `treasury`
- Transfiere `amountOut` al `to`
- Emite `Swap`

#### `getSpotPrice(address tokenIn) external view returns (uint256 price)`
- Devuelve precio spot de `tokenIn` en términos del otro token
- Fórmula: `reserveOut * 1e18 / reserveIn` (precio en 18 decimales)
- Solo para consulta externa; NO usarlo como oráculo de precios en contratos

#### `setFeeBps(uint256 newFeeBps) external`
- Restricción de acceso: `require(msg.sender == dao, "OnlyDAO")`
- Restricción de valor: `1 <= newFeeBps <= 1000`
- Emite `FeeUpdated`

#### `getReserves() external view returns (uint256, uint256)`
- Devuelve `(reserveA, reserveB)`

### Relaciones con otros contratos
- Transfiere fees a **DAOTreasury** en cada swap
- Es gobernado por **DAO** (cambio de fee via propuesta)
- Sus LP tokens son stakeados en **YieldFarmingPool**

### Consideraciones de seguridad
- **Reservas contables vs `balanceOf`:** usar `reserveA`/`reserveB` en lugar de `balanceOf(address(this))` previene el vector de donación forzada que rompería la fórmula k
- **Inflation attack en primer depósito:** quemar `MINIMUM_LIQUIDITY` hacia `address(1)` hace que manipular el precio de la share requiera un capital prohibitivo
- **Slippage y deadline en todas las operaciones de usuario:** `minAmountOut` y `deadline` son obligatorios en `swap`, `addLiquidity` y `removeLiquidity`
- **Read-only reentrancy:** `getSpotPrice` devuelve valores de las reservas contables; si otro contrato la llama durante un swap en curso (mid-execution), recibirá un precio de reservas ya actualizadas por CEI, lo cual es correcto. Documentar que no es adecuada como oráculo externo
- **Precio spot como oráculo:** la función `getSpotPrice` es manipulable con flash loans; documentar explícitamente que no debe usarse como precio de referencia en otros contratos. Para integraciones que necesiten precio fiable, usar un TWAP
- **División entera:** en el cálculo de `amountOut` (fórmula k), verificar que no se produzca división por cero cuando `reserveOut = 0`

---

## src/core/YieldFarmingPool.sol

### Propósito
Contrato de staking de LP tokens que distribuye GovernanceToken como recompensa continua a los stakers. Usa el patrón reward-per-token acumulado (estilo Synthetix/MasterChef) para soportar múltiples usuarios simultáneos con cálculo O(1) por usuario. La tasa de recompensa (`rewardRate`) es gobernable por la DAO.

### Herencias OpenZeppelin

| Contrato OZ | Por qué |
|---|---|
| `ReentrancyGuard` | Todas las funciones con transferencias externas |
| `Ownable` | Owner temporalmente gestiona el setup; luego la DAO controla via `setRewardRate` |

### Variables de estado

| Nombre | Tipo | Visibilidad | Descripción |
|---|---|---|---|
| `lpToken` | `address` | `public immutable` | Token LP que los usuarios stakean |
| `govToken` | `address` | `public immutable` | GovernanceToken que se distribuye como recompensa |
| `dao` | `address` | `public` | Único que puede cambiar `rewardRate` |
| `rewardRate` | `uint256` | `public` | Tokens de recompensa por segundo emitidos en total (en wei) |
| `rewardPerTokenStored` | `uint256` | `public` | Acumulador global escalado 1e18. Crece monotónicamente |
| `lastUpdateTime` | `uint256` | `public` | Último timestamp en que se actualizó el acumulador |
| `totalStaked` | `uint256` | `public` | Total de LP tokens stakeados actualmente |
| `balances` | `mapping(address => uint256)` | `public` | LP tokens stakeados por usuario |
| `userRewardPerTokenPaid` | `mapping(address => uint256)` | `public` | Snapshot del acumulador en el último punto de sincronización del usuario |
| `rewards` | `mapping(address => uint256)` | `public` | Rewards acumulados pendientes de claim por usuario |

### Eventos

| Nombre | Parámetros | Cuándo se emite |
|---|---|---|
| `Staked` | `address indexed user, uint256 amount` | En `stake` |
| `Unstaked` | `address indexed user, uint256 amount` | En `unstake` |
| `RewardHarvested` | `address indexed user, uint256 reward` | En `harvest` y en `exit` |
| `RewardRateUpdated` | `uint256 oldRate, uint256 newRate` | En `setRewardRate` |
| `DAOSet` | `address indexed dao` | En `setDAO` |

### Errores (via `require`)

| Condición | Mensaje |
|---|---|
| Monto es cero | `"ZeroAmount"` |
| Balance insuficiente para unstake | `"InsufficientStake"` |
| Sin rewards que claimar | `"NoRewards"` |
| Llamante no es DAO | `"OnlyDAO"` |

### Funciones

#### `constructor(address lpToken_, address govToken_, uint256 initialRewardRate, address initialOwner)`
- Establece `lpToken`, `govToken`, `rewardRate`
- Restricciones: ninguna dirección puede ser `address(0)`

#### `setDAO(address dao_) external onlyOwner`
- Establece la DAO gobernante
- Emite `DAOSet`

#### `stake(uint256 amount) external nonReentrant`
- Orden obligatorio de operaciones (ver `defi-staking-patterns.md` §3):
  1. `require(amount > 0)`
  2. `_updateReward(msg.sender)` — sincroniza acumulador y rewards del usuario
  3. `balances[msg.sender] += amount`
  4. `totalStaked += amount`
  5. `IERC20(lpToken).safeTransferFrom(msg.sender, address(this), amount)`
  6. `emit Staked`

#### `unstake(uint256 amount) external nonReentrant`
- Orden:
  1. `require(amount > 0)` y `require(balances[msg.sender] >= amount)`
  2. `_updateReward(msg.sender)`
  3. `balances[msg.sender] -= amount`
  4. `totalStaked -= amount`
  5. `IERC20(lpToken).safeTransfer(msg.sender, amount)`
  6. `emit Unstaked`

#### `harvest() external nonReentrant`
- Llama `_updateReward(msg.sender)`
- Lee `rewards[msg.sender]`; require > 0
- Pone a cero `rewards[msg.sender]` **antes** de la transferencia (CEI)
- Llama `IGovernanceToken(govToken).mint(msg.sender, reward)` (o `_safeRewardTransfer`)
- `emit RewardHarvested`

#### `exit() external nonReentrant`
- Equivale a `unstake(balances[msg.sender])` + `harvest()` en una sola transacción
- Implementación: reutiliza la lógica interna, no hace doble call externa

#### `earned(address user) external view returns (uint256)`
- Devuelve rewards acumulados + pendientes sin modificar estado
- Fórmula: `rewards[user] + balances[user] * (rewardPerToken() - userRewardPerTokenPaid[user]) / 1e18`

#### `rewardPerToken() public view returns (uint256)`
- Si `totalStaked == 0`: devuelve `rewardPerTokenStored` (sin avanzar el acumulador)
- Si no: `rewardPerTokenStored + (block.timestamp - lastUpdateTime) * rewardRate * 1e18 / totalStaked`

#### `setRewardRate(uint256 newRate) external`
- Restricción: `require(msg.sender == dao, "OnlyDAO")`
- Llama `_updateReward(address(0))` primero para sincronizar el acumulador con el rate anterior
- Establece el nuevo `rewardRate`
- Emite `RewardRateUpdated`

#### `_updateReward(address user) internal`
- Actualiza `rewardPerTokenStored = rewardPerToken()`
- Actualiza `lastUpdateTime = block.timestamp`
- Si `user != address(0)`: actualiza `rewards[user] = earned(user)` y `userRewardPerTokenPaid[user] = rewardPerTokenStored`

#### `_safeRewardTransfer(address to, uint256 amount) internal`
- Cap al balance real de govToken en el contrato: `uint256 bal = IERC20(govToken).balanceOf(address(this)); if (amount > bal) amount = bal;`
- Solo transfiere si `amount > 0`
- Nota: aplica si el YieldFarmingPool tiene un balance pre-minted. Si usa mint directo, este método no aplica

### Relaciones con otros contratos
- Recibe LP tokens de **LiquidityPool** stakeados por el usuario
- Llama `mint` en **GovernanceToken** como titular de `MINTER_ROLE`
- Es gobernado por **DAO** (cambio de `rewardRate` via propuesta)

### Consideraciones de seguridad
- **Invariante crítica:** `_updateReward` debe llamarse **siempre** antes de modificar `balances` o `totalStaked`. Si el orden se invierte, el acumulador usará un `totalStaked` incorrecto y los rewards se descalibran permanentemente
- **División por cero:** `rewardPerToken()` protege el caso `totalStaked == 0` devolviendo el acumulador sin avanzar. Sin esta guarda, el primer staker del pool o el periodo con totalStaked=0 romperían la función
- **Cambio de rewardRate a mitad del periodo:** `setRewardRate` debe llamar `_updateReward(address(0))` antes de cambiar el rate; de lo contrario, el rate nuevo se aplicaría retroactivamente al periodo no contabilizado
- **Reentrancy en harvest:** rewards[user] se pone a cero antes del mint/transfer externo (CEI). Un token de recompensa malicioso no puede reentrar y reclamar rewards dos veces
- **nonReentrant en funciones públicas únicamente:** las funciones internas `_updateReward` y `_safeRewardTransfer` no deben llevar `nonReentrant` (causaría revert por reentrada en el lock compartido)

---

## src/dao/DAO.sol

### Propósito
Implementación propia del contrato de gobernanza (no usa OZ Governor, intencionalmente didáctica). Gestiona el ciclo de vida completo de las propuestas: creación, votación, timelock y ejecución de llamadas arbitrarias hacia los contratos del protocolo.

### Herencias OpenZeppelin

| Contrato OZ | Por qué |
|---|---|
| `Ownable` | Owner configura parámetros iniciales del sistema |
| `ReentrancyGuard` | `execute()` realiza llamadas externas arbitrarias |

> No hereda de `Governor` para mantener la implementación autocontenida y auditable.

### Struct `Proposal`

```
struct Proposal {
    uint256 id
    address proposer
    address[] targets        // contratos a llamar
    uint256[] values         // ETH a enviar en cada call
    bytes[] calldatas        // calldata de cada call
    string description
    uint256 snapshotBlock    // bloque para leer getPastVotes
    uint256 startTime        // timestamp inicio de votación
    uint256 endTime          // timestamp fin de votación
    uint256 executionTime    // endTime + timelockDelay
    uint256 forVotes
    uint256 againstVotes
    bool executed
    bool canceled
    mapping(address => bool) hasVoted
}
```

### Estados posibles de una propuesta

| Estado | Condición |
|---|---|
| `Pending` | `block.timestamp < startTime` (periodo antes de que abra la votación) |
| `Active` | `startTime <= block.timestamp < endTime && !canceled` |
| `Defeated` | `block.timestamp >= endTime && (forVotes <= againstVotes \|\| !quorumReached)` |
| `Succeeded` | `block.timestamp >= endTime && forVotes > againstVotes && quorumReached && !executed && !canceled` |
| `Queued` | `Succeeded && block.timestamp < executionTime` (en timelock) |
| `Executed` | `executed == true` |
| `Canceled` | `canceled == true` |

### Variables de estado

| Nombre | Tipo | Visibilidad | Descripción |
|---|---|---|---|
| `govToken` | `address` | `public immutable` | GovernanceToken para leer voting power |
| `treasury` | `address` | `public immutable` | DAOTreasury gobernado |
| `proposals` | `mapping(uint256 => Proposal)` | `public` | Almacén de todas las propuestas |
| `proposalCount` | `uint256` | `public` | Contador monotónico; también es el ID de la siguiente propuesta |
| `votingPeriod` | `uint256` | `public` | Duración en segundos del periodo de votación (default: 3 días = 259200) |
| `timelockDelay` | `uint256` | `public` | Retraso en segundos entre fin de votación y ejecución (default: 1 día = 86400) |
| `quorumBps` | `uint256` | `public` | Porcentaje del supply total requerido como quórum (en bps, ej. 400 = 4%) |
| `proposalThreshold` | `uint256` | `public` | Mínimo de tokens (en wei) para crear una propuesta |

### Eventos

| Nombre | Parámetros | Cuándo se emite |
|---|---|---|
| `ProposalCreated` | `uint256 indexed id, address indexed proposer, string description, uint256 startTime, uint256 endTime` | En `propose` |
| `VoteCast` | `uint256 indexed proposalId, address indexed voter, bool support, uint256 weight` | En `castVote` |
| `ProposalExecuted` | `uint256 indexed id` | En `execute` |
| `ProposalCanceled` | `uint256 indexed id` | En `cancel` |
| `ParameterUpdated` | `string indexed param, uint256 oldValue, uint256 newValue` | Cada vez que se actualiza un parámetro de gobernanza |

### Errores (via `require`)

| Condición | Mensaje |
|---|---|
| No alcanza `proposalThreshold` | `"BelowProposalThreshold"` |
| Arrays de targets/values/calldatas con longitudes distintas | `"ArityMismatch"` |
| Arrays vacíos | `"EmptyProposal"` |
| Propuesta no existe | `"ProposalNotFound"` |
| Propuesta no está Active | `"VotingNotActive"` |
| Votante ya votó | `"AlreadyVoted"` |
| Votante sin poder de voto en el snapshot | `"NoVotingPower"` |
| Propuesta no está en estado Succeeded | `"ProposalNotSucceeded"` |
| Aún en timelock | `"TimelockActive"` |
| Propuesta ya ejecutada | `"AlreadyExecuted"` |
| Llamante no es el proposer ni la DAO | `"NotAuthorized"` |
| Llamada arbitraria falló | `"ExecutionFailed"` |
| Solo la DAO puede cambiar parámetros | `"OnlyDAO"` |

### Funciones

#### `constructor(address govToken_, address treasury_, uint256 votingPeriod_, uint256 timelockDelay_, uint256 quorumBps_, uint256 proposalThreshold_, address initialOwner)`
- Inicializa todos los parámetros
- Restricciones: `govToken_` y `treasury_` no pueden ser `address(0)`; `quorumBps_ <= 10000`

#### `propose(address[] calldata targets, uint256[] calldata values, bytes[] calldata calldatas, string calldata description) external returns (uint256 proposalId)`
- Verifica `getPastVotes(msg.sender, block.number - 1) >= proposalThreshold`
- Crea la propuesta con `snapshotBlock = block.number`, `startTime = block.timestamp`, `endTime = block.timestamp + votingPeriod`
- Incrementa `proposalCount`
- Emite `ProposalCreated`

#### `castVote(uint256 proposalId, bool support) external`
- Verifica estado Active
- Verifica `!hasVoted[voter]`
- Lee `weight = IGovernanceToken(govToken).getPastVotes(msg.sender, proposal.snapshotBlock)`
- Acumula `forVotes` o `againstVotes`
- Marca `hasVoted[msg.sender] = true`
- Emite `VoteCast`

#### `execute(uint256 proposalId) external nonReentrant`
- Verifica estado Succeeded (quórum alcanzado, forVotes > againstVotes, fuera del timelock)
- **CEI:** establece `proposal.executed = true` ANTES de cualquier llamada externa
- Itera sobre `targets`/`values`/`calldatas` y ejecuta cada call: `(bool ok,) = targets[i].call{value: values[i]}(calldatas[i]); require(ok, "ExecutionFailed")`
- Emite `ProposalExecuted`

#### `cancel(uint256 proposalId) external`
- Solo el proposer o la propia DAO pueden cancelar
- Propuesta no debe estar ya ejecutada
- Establece `canceled = true`
- Emite `ProposalCanceled`

#### `state(uint256 proposalId) external view returns (ProposalState)`
- Función view que retorna el estado actual de la propuesta según las condiciones definidas arriba

#### `quorumReached(uint256 proposalId) public view returns (bool)`
- `forVotes + againstVotes >= quorumVotes()`

#### `quorumVotes() public view returns (uint256)`
- `IGovernanceToken(govToken).totalSupply() * quorumBps / 10000`

#### `setVotingPeriod(uint256 newPeriod) external`
- Restricción: `require(msg.sender == address(this), "OnlyDAO")` — solo ejecutable via propuesta
- Emite `ParameterUpdated`

#### `setTimelockDelay(uint256 newDelay) external`
- Ídem, solo ejecutable via propuesta

#### `setQuorumBps(uint256 newQuorumBps) external`
- Ídem; `newQuorumBps <= 10000`

#### `setProposalThreshold(uint256 newThreshold) external`
- Ídem, solo ejecutable via propuesta

### Relaciones con otros contratos
- Lee `getPastVotes` de **GovernanceToken**
- Ejecuta llamadas a **LiquidityPool**, **YieldFarmingPool**, **DAOTreasury**
- Referenciado por **DAOTreasury** como único caller autorizado

### Consideraciones de seguridad
- **Snapshot de voting power:** leer `getPastVotes(voter, snapshotBlock)` en lugar del balance actual impide que un atacante compre tokens justo antes de votar y los venda inmediatamente después (flash loan governance attack)
- **Timelock obligatorio:** toda propuesta aprobada tiene un retraso mínimo entre el fin de la votación y la ejecución, dando tiempo a la comunidad para reaccionar ante propuestas maliciosas
- **CEI en `execute`:** `proposal.executed = true` antes de las llamadas externas. Si una llamada revierte, la propuesta queda marcada como ejecutada pero el efecto real no ocurrió — diseñar las acciones individuales como atómicas o usar try/catch si se necesita ejecución parcial
- **Flash loan en gobernanza:** mitigado por snapshots de ERC20Votes. Una propuesta creada en el bloque N usa el poder de voto del bloque N-1; un flash loan dentro del bloque N no puede modificar el snapshot del bloque anterior
- **Reentrancy en `execute`:** `nonReentrant` + CEI. Targets maliciosos no pueden reentrar en `execute` para ejecutar dos veces
- **Automodificación de parámetros:** los setters de parámetros (votingPeriod, quorumBps, etc.) solo pueden ser llamados si `msg.sender == address(this)`, es decir, solo desde dentro de una llamada en `execute`. Esto garantiza que cambiar parámetros requiere pasar por el proceso de gobernanza
- **Unbounded loop en `execute`:** el array `targets` puede tener longitud arbitraria. Mitigación: documentar un límite máximo de acciones por propuesta (ej. 10) y aplicarlo en `propose`

---

## src/dao/DAOTreasury.sol

### Propósito
Contrato de custodia que acumula los fees del protocolo (ETH y ERC20) y solo puede ser drenado mediante propuestas aprobadas por la DAO. Proporciona una separación de responsabilidades clara: el DAO decide, el Treasury ejecuta.

### Herencias OpenZeppelin

| Contrato OZ | Por qué |
|---|---|
| `Ownable` | Owner inicial llama a `setDAO` durante el bootstrap; luego el owner puede renunciar |
| `ReentrancyGuard` | Las funciones de retiro realizan transferencias externas |

### Variables de estado

| Nombre | Tipo | Visibilidad | Descripción |
|---|---|---|---|
| `dao` | `address` | `public` | Única dirección autorizada a llamar funciones de gasto |

### Eventos

| Nombre | Parámetros | Cuándo se emite |
|---|---|---|
| `ETHReceived` | `address indexed sender, uint256 amount` | En `receive()` |
| `TreasuryAction` | `address indexed token, address indexed to, uint256 amount, string reason` | En cada `withdrawETH` o `withdrawERC20` |
| `DAOSet` | `address indexed oldDAO, address indexed newDAO` | En `setDAO` |

### Errores (via `require`)

| Condición | Mensaje |
|---|---|
| Llamante no es la DAO | `"OnlyDAO"` |
| Balance ETH insuficiente | `"InsufficientETH"` |
| Balance ERC20 insuficiente | `"InsufficientTokenBalance"` |
| Dirección `to` es cero | `"ZeroAddress"` |
| Monto es cero | `"ZeroAmount"` |
| `setDAO` con dirección cero | `"ZeroAddress"` |
| `setDAO` con DAO ya configurado (si se quiere inmutabilidad) | `"DAOAlreadySet"` |
| Transferencia de ETH falló | `"ETHTransferFailed"` |

### Funciones

#### `constructor(address initialDAO)`
- Si `initialDAO != address(0)`, establece `dao = initialDAO`
- Acepta `address(0)` para el caso del bootstrap (se llama `setDAO` después)

#### `receive() external payable`
- Acepta ETH entrante (fees del protocolo, donaciones)
- Emite `ETHReceived`

#### `setDAO(address newDAO) external onlyOwner`
- Establece o actualiza la dirección del DAO gobernante
- Restricción: `newDAO != address(0)`
- Emite `DAOSet`
- Decisión de diseño: una vez configurado en producción, el owner debería renunciar para que el treasury solo sea controlable por la DAO

#### `withdrawETH(address to, uint256 amount, string calldata reason) external nonReentrant`
- Restricción de acceso: `require(msg.sender == dao, "OnlyDAO")`
- Restricciones de valor: `to != address(0)`, `amount > 0`, `address(this).balance >= amount`
- CEI: emite `TreasuryAction` antes de la transferencia (el evento es el registro inmutable; la transferencia puede fallar pero el intent ya está logueado)
- Transferencia: `(bool ok,) = to.call{value: amount}(""); require(ok, "ETHTransferFailed")`

> **Alternativa CEI:** algunos diseños registran el evento después de la transferencia exitosa para evitar eventos "falsos". Decidir cuál se prefiere y documentarlo. La recomendación es: evento después de transferencia exitosa para consistencia.

#### `withdrawERC20(address token, address to, uint256 amount, string calldata reason) external nonReentrant`
- Restricción de acceso: `require(msg.sender == dao, "OnlyDAO")`
- Restricciones de valor: `token != address(0)`, `to != address(0)`, `amount > 0`
- Verificar balance: `IERC20(token).balanceOf(address(this)) >= amount`
- Usa `IERC20(token).safeTransfer(to, amount)` (SafeERC20 de OZ para tokens no estándar)
- Emite `TreasuryAction`

#### `getETHBalance() external view returns (uint256)`
- `return address(this).balance`

#### `getTokenBalance(address token) external view returns (uint256)`
- `return IERC20(token).balanceOf(address(this))`

### Relaciones con otros contratos
- Recibe ETH/tokens de **LiquidityPool** (fees de swap)
- Solo acepta instrucciones de gasto de **DAO**

### Consideraciones de seguridad
- **Single-caller invariant:** el modifier `onlyDAO` (implementado como `require(msg.sender == dao, "OnlyDAO")`) es el único perímetro de seguridad del treasury. Su corrección es crítica
- **Bootstrap deadlock:** durante el deploy, la DAO aún no existe cuando se despliega el treasury. La solución (pasar `address(0)` y llamar `setDAO` después) crea una ventana de vulnerabilidad si el deployer es comprometido. Mitigación: usar un script de deploy atómico que haga todo en una transacción, o restringir `setDAO` para que solo pueda llamarse cuando `dao == address(0)`
- **Reentrancy en withdrawETH:** `call{value: amount}` puede disparar código en el receptor. CEI + `nonReentrant` mitigan esto. El estado (marcado en el evento) ya está registrado antes de la llamada
- **Donaciones de ETH forzado:** tokens enviados con `selfdestruct` o coinbase serían capturados por `receive()` y registrados. No usar `address(this).balance` para contabilidad interna crítica; llevar un `accumulatedFees` separado si se necesita precisión contable
- **SafeERC20:** necesario para tokens que no devuelven `bool` en `transfer` (ej. USDT). Sin él, la llamada a `transfer` podría silenciosamente fallar en ciertos tokens

---

## src/interfaces/ILiquidityPool.sol

### Propósito
Expone las funciones de LiquidityPool que otros contratos del sistema necesitan llamar. No incluye funciones administrativas (`setFeeBps`, `setDAO`).

### Funciones a incluir

```solidity
function addLiquidity(uint256 amountADesired, uint256 amountBDesired, uint256 amountAMin, uint256 amountBMin, address to, uint256 deadline) external returns (uint256 lpMinted);
function removeLiquidity(uint256 lpAmount, uint256 amountAMin, uint256 amountBMin, address to, uint256 deadline) external returns (uint256 amountA, uint256 amountB);
function swap(address tokenIn, uint256 amountIn, uint256 minAmountOut, address to, uint256 deadline) external returns (uint256 amountOut);
function getReserves() external view returns (uint256 reserveA, uint256 reserveB);
function getSpotPrice(address tokenIn) external view returns (uint256 price);
function feeBps() external view returns (uint256);
function tokenA() external view returns (address);
function tokenB() external view returns (address);
```

---

## src/interfaces/IYieldFarmingPool.sol

### Propósito
Expone las funciones de YieldFarmingPool que la DAO necesita llamar (principalmente `setRewardRate`) y que el frontend/integradores necesitan leer.

### Funciones a incluir

```solidity
function stake(uint256 amount) external;
function unstake(uint256 amount) external;
function harvest() external;
function exit() external;
function earned(address user) external view returns (uint256);
function rewardPerToken() external view returns (uint256);
function rewardRate() external view returns (uint256);
function totalStaked() external view returns (uint256);
function balances(address user) external view returns (uint256);
function setRewardRate(uint256 newRate) external;
```

---

## src/interfaces/IDAO.sol

### Propósito
Expone las funciones de DAO que DAOTreasury y otros contratos necesitan para verificar el origen de las llamadas o leer el estado de propuestas.

### Funciones a incluir

```solidity
function propose(address[] calldata targets, uint256[] calldata values, bytes[] calldata calldatas, string calldata description) external returns (uint256 proposalId);
function castVote(uint256 proposalId, bool support) external;
function execute(uint256 proposalId) external;
function cancel(uint256 proposalId) external;
function state(uint256 proposalId) external view returns (uint8);
function quorumVotes() external view returns (uint256);
function proposalCount() external view returns (uint256);
function votingPeriod() external view returns (uint256);
function timelockDelay() external view returns (uint256);
```

---

## src/interfaces/IDAOTreasury.sol

### Propósito
Expone las funciones de DAOTreasury que la DAO llama al ejecutar propuestas de retiro de fondos.

### Funciones a incluir

```solidity
function withdrawETH(address to, uint256 amount, string calldata reason) external;
function withdrawERC20(address token, address to, uint256 amount, string calldata reason) external;
function getETHBalance() external view returns (uint256);
function getTokenBalance(address token) external view returns (uint256);
function setDAO(address newDAO) external;
```

---

## test/GovernanceToken.t.sol

### Propósito
Tests unitarios, fuzz e invariantes de GovernanceToken.

### `contract GovernanceTokenTest is Test`

**Actores:**
```solidity
address internal owner    = vm.addr(1);
address internal minter   = vm.addr(2);   // simulará el YieldFarmingPool
address internal user     = vm.addr(3);
address internal attacker = vm.addr(4);
```

**Casos a cubrir:**

| Tipo | Descripción |
|---|---|
| Unit | Deploy correcto: nombre, símbolo, maxSupply, owner |
| Unit | `mint` con `MINTER_ROLE`: acuña correctamente |
| Unit | `mint` sin rol: revert `AccessControlUnauthorizedAccount` (error OZ, no require) |
| Unit | `mint` que supera maxSupply: revert `"SupplyExceeded"` |
| Unit | `burn` por el holder: reduce supply correctamente |
| Unit | `permit`: firma off-chain aprueba correctamente (usa `vm.sign`) |
| Unit | `delegate` + `getPastVotes`: snapshot funciona correctamente con `vm.roll` |
| Fuzz | `fuzz_mint(uint256 amount)`: cualquier amount <= restante aceptado; cualquier amount > restante rechazado |
| Invariant | `invariant_supplyNeverExceedsMax`: `totalSupply() <= maxSupply_` siempre |

---

## test/LiquidityPool.t.sol

### Propósito
Tests unitarios y fuzz de LiquidityPool.

### `contract LiquidityPoolTest is Test`

**Actores:**
```solidity
address internal owner    = vm.addr(1);
address internal lp1      = vm.addr(2);
address internal lp2      = vm.addr(3);
address internal trader   = vm.addr(4);
address internal attacker = vm.addr(5);
address internal treasury = vm.addr(6);
address internal dao      = vm.addr(7);
```

**Casos a cubrir:**

| Tipo | Descripción |
|---|---|
| Unit | Primer `addLiquidity`: acuña LP correctamente, quema MINIMUM_LIQUIDITY |
| Unit | Segundo `addLiquidity`: mantiene la ratio del pool |
| Unit | `removeLiquidity`: devuelve tokens proporcionales |
| Unit | `swap` A→B: aplica fórmula k, descuenta fee, envía treasuryFee |
| Unit | `swap` B→A: ídem en dirección opuesta |
| Unit | `swap` con slippage excedido: revert `"SlippageExceeded"` |
| Unit | `swap` con deadline vencido: revert `"Expired"` |
| Unit | `setFeeBps` por DAO: actualiza correctamente |
| Unit | `setFeeBps` por no-DAO: revert `"OnlyDAO"` |
| Unit | `getSpotPrice`: devuelve precio correcto con reservas conocidas |
| Fuzz | `fuzz_swap(uint256 amountIn)`: el invariante k nunca disminuye (post-fee al pool) |
| Invariant | `invariant_kNeverDecreases`: `reserveA * reserveB >= k_inicial` (verificar que el pool no pierde valor por bugs de redondeo) |

---

## test/YieldFarmingPool.t.sol

### Propósito
Tests del patrón reward-per-token, incluyendo casos de edge con múltiples stakers y cambios de tasa.

### `contract YieldFarmingPoolTest is Test`

**Actores:**
```solidity
address internal owner  = vm.addr(1);
address internal user1  = vm.addr(2);
address internal user2  = vm.addr(3);
address internal dao    = vm.addr(4);
```

**Casos a cubrir:**

| Tipo | Descripción |
|---|---|
| Unit | `stake`: incrementa balance y totalStaked |
| Unit | `unstake`: decrementa balance y totalStaked, devuelve tokens |
| Unit | `harvest`: transfiere rewards correctos y los pone a cero |
| Unit | `exit`: unstake total + harvest en una tx |
| Unit | Dos usuarios stakean simultáneamente: rewards proporcionales al stake |
| Unit | `stake` con amount=0: revert `"ZeroAmount"` |
| Unit | `unstake` más de lo stakeado: revert `"InsufficientStake"` |
| Unit | `earned` aumenta con el tiempo (`vm.warp`) |
| Unit | `setRewardRate` por DAO: rewards previos no se pierden |
| Unit | `setRewardRate` por no-DAO: revert `"OnlyDAO"` |
| Unit | totalStaked=0 durante un periodo: acumulador no avanza (no divide por cero) |
| Fuzz | `fuzz_stakeAndEarn(uint256 amount, uint256 time)`: rewards nunca negativos |
| Invariant | `invariant_totalRewardsDistributedNeverExceedsEmitted`: suma de `earned` ≤ rewards teóricamente emitidos |

---

## test/DAO.t.sol

### Propósito
Tests del ciclo completo de gobernanza.

### `contract DAOTest is Test`

**Actores:**
```solidity
address internal owner    = vm.addr(1);
address internal proposer = vm.addr(2);
address internal voter1   = vm.addr(3);
address internal voter2   = vm.addr(4);
address internal attacker = vm.addr(5);
```

**Casos a cubrir:**

| Tipo | Descripción |
|---|---|
| Unit | `propose` con suficientes tokens: crea propuesta correctamente |
| Unit | `propose` bajo threshold: revert `"BelowProposalThreshold"` |
| Unit | `castVote` en Active: registra votos correctamente |
| Unit | `castVote` dos veces: revert `"AlreadyVoted"` |
| Unit | `castVote` fuera de periodo Active: revert `"VotingNotActive"` |
| Unit | Quórum alcanzado + mayoría: estado Succeeded |
| Unit | Quórum no alcanzado: estado Defeated |
| Unit | `execute` en Succeeded tras timelock: ejecuta correctamente |
| Unit | `execute` en timelock activo: revert `"TimelockActive"` |
| Unit | `execute` en Defeated: revert `"ProposalNotSucceeded"` |
| Unit | `cancel` por proposer: cancela correctamente |
| Unit | `cancel` por no-proposer: revert `"NotAuthorized"` |
| Unit | Propuesta automodifica `votingPeriod` via `execute` |
| Fuzz | `fuzz_voteWeights(uint256 forAmount, uint256 againstAmount)`: resultado correcto |

> **Nota de cobertura:** la rama `!proposal.executed` dentro de `castVote` es inalcanzable por la exclusión mutua de timestamps (ver `dao-governance.md` §Voting mechanics). Documentar explícitamente en el test como branch inalcanzable para evitar cazar un test imposible.

---

## test/DAOTreasury.t.sol

### Propósito
Tests de recepción de fondos y retiros, con cobertura de ambos paths (ETH y ERC20).

### `contract DAOTreasuryTest is Test`

**Actores:**
```solidity
address internal owner    = vm.addr(1);
address internal dao      = vm.addr(2);
address internal receiver = vm.addr(3);
address internal attacker = vm.addr(4);
```

**Casos a cubrir:**

| Tipo | Descripción |
|---|---|
| Unit | `receive()`: acepta ETH, emite `ETHReceived` |
| Unit | `withdrawETH` por DAO: transfiere correctamente, emite `TreasuryAction` |
| Unit | `withdrawETH` por no-DAO: revert `"OnlyDAO"` |
| Unit | `withdrawETH` con balance insuficiente: revert `"InsufficientETH"` |
| Unit | `withdrawERC20` por DAO: transfiere ERC20 correctamente |
| Unit | `withdrawERC20` por no-DAO: revert `"OnlyDAO"` |
| Unit | `withdrawERC20` con balance insuficiente: revert `"InsufficientTokenBalance"` |
| Unit | `setDAO` por owner: actualiza correctamente |
| Unit | `setDAO` con address(0): revert `"ZeroAddress"` |
| Unit | `getETHBalance` / `getTokenBalance`: devuelven valores correctos |

---

## test/Integration.t.sol

### Propósito
Test de integración end-to-end del flujo completo del protocolo. Verifica que todos los contratos funcionan juntos correctamente.

### `contract IntegrationTest is Test`

**Actores:**
```solidity
address internal deployer = vm.addr(1);
address internal lp       = vm.addr(2);   // proveedor de liquidez + farmer
address internal trader   = vm.addr(3);
address internal voter    = vm.addr(4);
```

**Escenarios a cubrir:**

| Escenario | Descripción |
|---|---|
| Flujo completo 1 | `lp` deposita en LiquidityPool → recibe LP tokens → stakea en YieldFarmingPool → acumula GovernanceToken → harvesta rewards |
| Flujo completo 2 | `trader` hace swaps → fee va al treasury → treasury aumenta ETH balance |
| Gobernanza | `voter` con GovernanceToken propone cambiar `rewardRate` → vota a favor → `vm.warp` al fin del periodo + timelock → `execute` → YieldFarmingPool tiene nuevo rate |
| Gobernanza | Propuesta de retirar fondos del treasury → aprobada → `withdrawETH` ejecutado |
| Edge | `lp` stakea, pasa tiempo, `lp` unstakea + harvesta: balance final correcto |
| Security | `attacker` intenta llamar directamente a `DAOTreasury.withdrawETH`: revert |
| Security | `attacker` intenta llamar `YieldFarmingPool.setRewardRate`: revert |

---

## test/mocks/MockERC20.sol

> **Nota de estilo:** El solidity-style rule establece que no debe haber subdirectorio `test/mocks/`. Si el linter lo bloquea, mover `MockERC20.sol` directamente a `test/MockERC20.sol`.

### Propósito
Token ERC20 simple para usar como `tokenA`, `tokenB` en los tests. No va a producción.

### Implementación esperada
- Hereda `ERC20` de OZ
- Constructor: `(string memory name, string memory symbol, uint8 decimals_)`
- Función `mint(address to, uint256 amount) external`: sin restricción de acceso (es un mock)
- Opcionalmente: `burn(address from, uint256 amount) external`

---

## script/Deploy.s.sol

### Propósito
Script de despliegue completo que sigue el orden de bootstrap definido arriba. Usa `vm.startBroadcast()` / `vm.stopBroadcast()`.

### Estructura esperada

Ver el orden de despliegue en la sección "Orden de despliegue" al inicio de este documento.

El script debe:
1. Leer parámetros del entorno (`vm.envAddress`, `vm.envUint`) en lugar de hardcodear valores
2. Deployar todos los contratos en el orden correcto
3. Llamar a `setDAO` en el treasury
4. Llamar a `grantRole(MINTER_ROLE, address(yieldFarmingPool))` en el govToken
5. Verificar postcondiciones: `treasury.dao() == address(dao)`, etc.
6. Emitir logs con las direcciones desplegadas (`console.log`)

> Ver `~/.claude/rules/solidity-deploy.md` para el skeleton y convenciones específicas del deploy script.

---

## Resumen de dependencias entre contratos

```
GovernanceToken
    ← mint ← YieldFarmingPool
    ← getPastVotes ← DAO

LiquidityPool
    → transferETH/ERC20 → DAOTreasury (fee 20%)
    ← setFeeBps ← DAO (via propuesta)

YieldFarmingPool
    ← stake/unstake ← Usuario (LP tokens de LiquidityPool)
    → mint → GovernanceToken (rewards)
    ← setRewardRate ← DAO (via propuesta)

DAO
    → execute → LiquidityPool (setFeeBps)
    → execute → YieldFarmingPool (setRewardRate)
    → execute → DAOTreasury (withdraw*)
    → execute → DAO itself (set*Params)
    ← castVote ← Holders de GovernanceToken

DAOTreasury
    ← receive ← LiquidityPool (fees)
    ← withdraw* ← DAO (única fuente autorizada)
```

---

## Checklist de seguridad global

- [ ] Todos los contratos con transferencias externas tienen `nonReentrant`
- [ ] Todas las funciones de transferencia siguen CEI estrictamente
- [ ] `tx.origin` no se usa en ningún control de acceso
- [ ] Ningún loop itera sobre arrays de longitud no acotada sin un límite máximo documentado
- [ ] Todos los parámetros de dirección se validan contra `address(0)`
- [ ] Slippage y deadline están presentes en todas las operaciones de swap/LP
- [ ] Los eventos cubren todos los cambios de estado relevantes
- [ ] El único caller del DAOTreasury es el contrato DAO
- [ ] El único minter del GovernanceToken es el YieldFarmingPool
- [ ] El voting power usa snapshots por bloque (ERC20Votes), no balances actuales
- [ ] El timelock impide ejecución inmediata de propuestas aprobadas
- [ ] El orden de despliegue está documentado y el script lo automatiza completamente
