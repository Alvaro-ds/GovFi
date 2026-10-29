// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "../../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import "../../lib/openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * @title GovernanceToken
 * @notice ERC20 governance token with on-chain voting power snapshots and gasless permit approvals.
 * @dev Only addresses holding MINTER_ROLE (in production: YieldFarmingPool) may mint new tokens.
 *      ERC20Votes snapshots voting power per block, preventing flash-loan governance attacks.
 *      Holders must call delegate(address(self)) to activate their own voting weight.
 */
contract GovernanceToken is ERC20, ERC20Permit, ERC20Votes, AccessControl, Ownable {
    /// @notice Role identifier for the address authorized to mint new tokens.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @dev Absolute supply cap established at deployment; never changes.
    uint256 private immutable maxSupply_;

    /// @notice Emitted when MINTER_ROLE is granted to a new address.
    event MinterRoleGranted(address indexed minter);

    /// @notice Emitted when MINTER_ROLE is revoked from an address.
    event MinterRoleRevoked(address indexed minter);

    /// @notice Emitted when a mint reaches exactly the supply cap.
    event MaxSupplyReached(uint256 currentSupply);

    /**
     * @notice Deploys the GovernanceToken and sets the immutable supply cap.
     * @dev Grants DEFAULT_ADMIN_ROLE and MINTER_ROLE to initialOwner so the deployer can wire up
     *      the ecosystem (reassign MINTER_ROLE to YieldFarmingPool) before renouncing admin rights.
     *      ERC20Permit(name) also initializes EIP-712 domain for ERC20Votes; order in inheritance
     *      list (ERC20Permit before ERC20Votes) is intentional.
     * @param cap          Absolute token supply cap. Must be greater than zero.
     * @param name         ERC20 token name.
     * @param symbol       ERC20 token symbol.
     * @param initialOwner Address that receives ownership, DEFAULT_ADMIN_ROLE, and MINTER_ROLE.
     */
    constructor(uint256 cap, string memory name, string memory symbol, address initialOwner) ERC20(name, symbol) ERC20Permit(name) Ownable(initialOwner) {
        require(cap > 0, "ZeroMaxSupply");
        require(initialOwner != address(0), "ZeroAddress");
        maxSupply_ = cap;
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        _grantRole(MINTER_ROLE, initialOwner);
    }

    /**
     * @notice Mints `amount` tokens to `to`.
     * @dev Reverts if the mint would exceed the supply cap. Emits MaxSupplyReached when the cap
     *      is filled exactly. Only callable by addresses holding MINTER_ROLE.
     * @param to     Recipient address. Cannot be address(0).
     * @param amount Number of tokens to mint (in wei).
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        require(totalSupply() + amount <= maxSupply_, "SupplyExceeded");
        _mint(to, amount);

        if (totalSupply() == maxSupply_) {
            emit MaxSupplyReached(totalSupply());
        }
    }

    /**
     * @notice Burns `amount` tokens from the caller's balance.
     * @dev Any token holder may burn their own tokens; no special role required.
     * @param amount Number of tokens to burn (in wei).
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /**
     * @notice Returns the absolute supply cap set at deployment.
     * @return The maximum number of tokens that can ever exist (in wei).
     */
    function maxSupply() external view returns (uint256) {
        return maxSupply_;
    }

    /**
     * @notice Grants MINTER_ROLE to `minter`.
     * @dev Caller must hold DEFAULT_ADMIN_ROLE. In production call this once to assign the role
     *      to YieldFarmingPool, then transfer or renounce the admin role.
     * @param minter Address to receive the minting privilege. Cannot be address(0).
     */
    function grantMinterRole(address minter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(minter != address(0), "ZeroAddress");
        _grantRole(MINTER_ROLE, minter);
        emit MinterRoleGranted(minter);
    }

    /**
     * @notice Revokes MINTER_ROLE from `minter`.
     * @dev Caller must hold DEFAULT_ADMIN_ROLE.
     * @param minter Address to lose the minting privilege.
     */
    function revokeMinterRole(address minter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(MINTER_ROLE, minter);
        emit MinterRoleRevoked(minter);
    }

    /// @dev Resolves the diamond between ERC20 and ERC20Votes; both define _update.
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    /// @dev Resolves the diamond between ERC20Permit and Nonces; both define nonces.
    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
