// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract NFTProtocolDEX is ERC1155Holder, ERC721Holder, ReentrancyGuard {
    using SafeMath for uint256;
    using Address for address;
    using SafeERC20 for IERC20;

    /// @dev Event triggered when a swap was opened, see :sol:func:`make`.
    /// @param make array of swap components on the maker side, see :sol:struct:`Component`.
    /// @param take array of swap components on the taker side, see :sol:struct:`Component`.
    /// @param whitelist array of addresses that are allowed to take the swap.
    /// @param id id of the swap.
    event MakeSwap(
        Component[] make,
        Component[] take,
        address indexed makerAddress,
        address[] whitelist,
        uint256 indexed id
    );

    /// @dev Emitted when a swap was executed, see :sol:func:`take`.
    /// @param swapId id of the swap that was taken.
    /// @param takerAddress address of the account that executed the swap.
    /// @param fee WEI of ETHER that was paid for the swap.
    event TakeSwap(uint256 swapId, address takerAddress, uint256 fee);

    /// @dev Emitted when a swap was dropped, ie. cancelled.
    /// @param swapId id of the dropped swap.
    event DropSwap(uint256 swapId);

    /// @dev Emitted when fee parameters have changed, see :sol:func:`vote`, :sol:func:`fees`.
    /// @param flatFee fee to be paid by a swap taker in WEI of ETHER.
    /// @param feeBypassLow threshold of NFT Protocol tokens to be held by a swap taker in order to get a 10% fee discount.
    /// @param feeBypassHigh threshold of NFT Protocol tokens to be held by a swap taker in order to pay no fees.
    event Vote(uint256 flatFee, uint256 feeBypassLow, uint256 feeBypassHigh);

    /// @dev Multisig address for administrative functions.
    address public msig;

    /// @dev Address of the ERC20 NFT Protcol token.
    address public immutable nftProtocolTokenAddress;

    /// @dev Flat fee for all trades in WEI of ETHER, default is 0.001 ETHER.
    /// The flat fee can be changed by the multisig account, see :sol:func:`vote`.
    uint256 public flat = 1000000000000000;

    /// @dev Indicates if the DEX is locked down in case of an emergency.
    /// The value is `true` if the DEX is locked, `false` otherwise.
    bool public locked = false;

    /// @dev Low threshold of NFT Protocol token balance where a 10% fee discount is enabled.
    /// See :sol:func:`fees`, :sol:func:`vote`.
    uint256 public felo = 10000 * 10**18;

    /// @dev High threshold of NFT Protocol token balance where fees are waived.
    /// See :sol:func:`fees`, :sol:func:`vote`.
    uint256 public fehi = 100000 * 10**18;

    // Maker and taker side
    uint8 private constant LEFT = 0;
    uint8 private constant RIGHT = 1;

    /// @dev Asset type 0 for ERC1155 swap components.
    uint8 public constant ERC1155_ASSET = 0;

    /// @dev Asset type 1 for ERC721 swap components.
    uint8 public constant ERC721_ASSET = 1;

    /// @dev Asset type 2 for ERC20 swap components.
    uint8 public constant ERC20_ASSET = 2;

    /// @dev Asset type 3 for ETHER swap components.
    uint8 public constant ETHER_ASSET = 3;

    /// @dev Swap status 0 for swaps that are open and active.
    uint8 public constant OPEN_SWAP = 0;

    /// @dev Swap status 1 for swaps that are closed.
    uint8 public constant CLOSED_SWAP = 1;

    /// @dev Swap status 2 for swaps that are dropped, ie. cancelled.
    uint8 public constant DROPPED_SWAP = 2;

    // Swap structure.
    struct Swap {
        uint256 id;
        uint8 status;
        Component[][2] components;
        address makerAddress;
        address takerAddress;
        bool whitelistEnabled;
    }

    /// Structure representing a single component of a swap.
    struct Component {
        uint8 assetType;
        address tokenAddress;
        uint256[] tokenIds;
        uint256[] amounts;
    }

    /// @dev Map holding all swaps (including cancelled and executed swaps).
    mapping(uint256 => Swap) public swap;

    // Total number of swaps in the database.
    uint256 public size;

    /// @dev Map from swapId to whitelist of a swap.
    mapping(uint256 => mapping(address => bool)) public list;

    // Map holding pending eth withdrawals.
    mapping(address => uint256) private pendingWithdrawals;

    // Maps to track the contract owned user balances for Ether.
    // The multisig account will not be able to withdraw assets that are owned by users.
    uint256 private usersEthBalance;

    // Unlocked DEX function modifier.
    modifier unlocked {
        require(!locked, "DEX shut down");
        _;
    }

    // Only msig caller function modifier.
    modifier onlyMsig {
        require(msg.sender == msig, "Unauthorized");
        _;
    }

    /// @dev Initializes the contract by setting the address of the NFT Protocol token
    /// and multisig (administrator) account.
    /// @param _nftProtocolToken address of the NFT Protocol ERC20 token
    /// @param _multisig address of the administrator account
    constructor(address _nftProtocolToken, address _multisig) {
        msig = _multisig;
        nftProtocolTokenAddress = _nftProtocolToken;
        emit Vote(flat, felo, fehi);
    }

    /// @dev Opens a swap with a list of assets on the maker side (_make) and on the taker side (_take).
    ///
    /// All assets listed on the maker side have to be available in the caller's account.
    /// They are transferred to the DEX contract during this contract call.
    ///
    /// If the maker list contains ETHER assets, then the total ETHER funds have to be sent along with
    /// the message of this contract call.
    ///
    /// Emits a :sol:event:`MakeSwap` event.
    ///
    /// @param _make array of components for the maker side of the swap.
    /// @param _take array of components for the taker side of the swap.
    /// @param _whitelist list of addresses that shall be permitted to take the swap.
    /// If empty, then whitelisting will be disabled for this swap.
    function make(
        Component[] calldata _make,
        Component[] calldata _take,
        address[] calldata _whitelist
    ) external payable nonReentrant unlocked {
        // Prohibit multisig from making swap to maintain correct users balances.
        require(msg.sender != msig, "Multisig cannot make swap");
        require(_take.length > 0, "Empty taker array");
        require(_make.length > 0, "Empty maker array");

        // Check all values before changing state.
        checkAssets(_take);
        uint256 totalEther = checkAssets(_make);
        require(msg.value >= totalEther, "Insufficient ETH");

        // Initialize whitelist mapping for this swap.
        swap[size].whitelistEnabled = _whitelist.length > 0;
        for (uint256 i = 0; i < _whitelist.length; i++) {
            list[size][_whitelist[i]] = true;
        }

        // Create swap entry and transfer assets to DEX.
        swap[size].id = size;
        swap[size].makerAddress = msg.sender;
        for (uint256 i = 0; i < _take.length; i++) {
            swap[size].components[RIGHT].push(_take[i]);
        }
        for (uint256 i = 0; i < _make.length; i++) {
            swap[size].components[LEFT].push(_make[i]);
        }

        // Account for Ether from this message.
        usersEthBalance += msg.value;

        // Credit excess Ether back to the sender.
        if (msg.value > totalEther) {
            pendingWithdrawals[msg.sender] += msg.value - totalEther;
        }

        // Add swap.
        size += 1;

        // Transfer in maker assets.
        for (uint256 i = 0; i < _make.length; i++) {
            transferAsset(_make[i], msg.sender, address(this));
        }

        // Issue event.
        emit MakeSwap(_make, _take, msg.sender, _whitelist, size - 1);
    }

    /// @dev Takes a swap that is currently open.
    ///
    /// All assets listed on the taker side have to be available in the caller's account, see :sol:func:`make`.
    /// They are transferred to the maker's account in exchange for the maker's assets (that currently reside within the DEX contract),
    /// which are transferred to the taker's account.
    ///
    /// The fee for this trade has to be sent along with the message of this contract call, see :sol:func:`fees`.
    ///
    /// If the taker list contains ETHER assets, then the total ETHER value also has to be added in WEI to the value that is sent along with
    /// the message of this contract call.
    ///
    /// @param _swapId id of the swap to be taken.
    function take(uint256 _swapId) external payable nonReentrant unlocked {
        // Prohibit multisig from taking swap to maintain correct users balances.
        require(msg.sender != msig, "Multisig cannot take swap");

        // Get SwapData from the swap hash.
        require(_swapId < size, "Invalid swapId");
        Swap memory swp = swap[_swapId];
        require(swp.status == OPEN_SWAP, "Swap not open");

        // Check if address attempting to fulfill swap is authorized in the whitelist.
        require(!swp.whitelistEnabled || list[_swapId][msg.sender], "Not whitelisted");

        // Determine how much total Ether has to be provided by the sender, including fees.
        uint256 totalEther = checkAssets(swp.components[RIGHT]);
        uint256 fee = fees();
        require(msg.value >= totalEther + fee, "Insufficient ETH (price+fee)");

        // Close out swap.
        swap[_swapId].status = CLOSED_SWAP;
        swap[_swapId].takerAddress = msg.sender;

        // Account for Ether from this message.
        usersEthBalance += totalEther;

        // Credit excess eth back to the sender.
        if (msg.value > totalEther + fee) {
            pendingWithdrawals[msg.sender] += msg.value - totalEther - fee;
        }

        // Transfer assets from DEX to taker.
        for (uint256 i = 0; i < swp.components[LEFT].length; i++) {
            transferAsset(swp.components[LEFT][i], address(this), msg.sender);
        }

        // Transfer assets from taker to maker.
        for (uint256 i = 0; i < swp.components[RIGHT].length; i++) {
            transferAsset(swp.components[RIGHT][i], msg.sender, swp.makerAddress);
        }

        // Issue event.
        emit TakeSwap(_swapId, msg.sender, fee);
    }

    /// @dev Cancel a swap and return the assets on the maker side back to the maker.
    ///
    /// All ERC1155, ERC721, and ERC20 assets will the transferred back directly to the maker.
    /// ETH assets are booked to the maker account and can be extracted via :sol:func:`pull`.
    ///
    /// Only the swap maker will be able to call this function successfully.
    ///
    /// Only swaps that are currently open can be dropped.
    ///
    /// @param _swapId id of the swap to be dropped.
    function drop(uint256 _swapId) external nonReentrant unlocked {
        Swap memory swp = swap[_swapId];
        require(msg.sender == swp.makerAddress, "Not swap maker");
        require(swap[_swapId].status == OPEN_SWAP, "Swap not open");

        // Drop swap.
        swap[_swapId].status = DROPPED_SWAP;

        // Transfer assets back to maker.
        for (uint256 i = 0; i < swp.components[LEFT].length; i++) {
            transferAsset(swp.components[LEFT][i], address(this), swp.makerAddress);
        }

        // Issue event.
        emit DropSwap(_swapId);
    }

    /// @dev WEI of ETHER that can be withdrawn by a user, see :sol:func:`pull`.
    function pend() public view returns (uint256) {
        return pendingWithdrawals[msg.sender];
    }

    /// @dev Withdraw ETHER funds from the contract, see :sol:func:`pend`.
    function pull() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        pendingWithdrawals[msg.sender] = 0;
        if (msg.sender != msig) {
            // Underflow should never happen and is handled by SafeMath if it does.
            usersEthBalance -= amount;
        }
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "Ether transfer failed");
    }

    /// @dev Calculate the fee owed for a trade.
    /// This function is usually called by the taker to determine the amount of ETH
    /// that has to be paid for a trade.
    /// @return fees in WEI of ETHER to be paid by the caller as a taker.
    function fees() public view returns (uint256) {
        uint256 balance = IERC20(nftProtocolTokenAddress).balanceOf(msg.sender);
        if (balance >= fehi) {
            return 0;
        }
        if (balance < felo) {
            return flat;
        }
        // Take 10% off as soon as feeBypassLow is reached.
        uint256 startFee = (flat * 9) / 10;
        return startFee - (startFee * (balance - felo)) / (fehi - felo);
    }

    /// @dev Governance votes to set fees.
    /// @param _flatFee flat fee in WEI of ETHER that has to be paid for a trade,
    /// if the taker has less than `_feeBypassLow` NFT Protocol tokens in its account.
    /// @param _feeBypassLow threshold of NFT Protocol tokens to be held by a swap taker in order to get a 10% fee discount.
    /// @param _feeBypassHigh threshold of NFT Protocol tokens to be held by a swap taker in order to pay no fees.
    function vote(
        uint256 _flatFee,
        uint256 _feeBypassLow,
        uint256 _feeBypassHigh
    ) external onlyMsig {
        require(_feeBypassLow <= _feeBypassHigh, "bypassLow must be <= bypassHigh");

        flat = _flatFee;
        felo = _feeBypassLow;
        fehi = _feeBypassHigh;

        emit Vote(_flatFee, _feeBypassLow, _feeBypassHigh);
    }

    /// @dev Shut down the DEX in case of an emergency.
    ///
    /// Only the :sol:func:`msig` will be able to call this function successfully.
    ///
    /// @param _locked `true` to lock down the DEX, `false` to unlock the DEX.
    function lock(bool _locked) external onlyMsig {
        locked = _locked;
    }

    /// @dev Set multisig ie. administrator account.
    ///
    /// Only the :sol:func:`msig` will be able to call this function successfully.
    ///
    /// @param _to address of the new multisig/admin account
    function auth(address _to) external onlyMsig {
        require(_to != address(0x0), "Cannot set to zero address");
        msig = _to;
    }

    /// @dev Rescue ETHER funds from the DEX that do not belong the a user, e.g., fees and ETHER that have been sent to the DEX accidentally.
    ///
    /// This function books the contract's ETHER funds that do not belong to a user, to the :sol:func:`msig` account and makes them
    /// available for withdrawal through :sol:func:`pull`.
    ///
    /// The user funds that were transfered to the DEX through :sol:func:`make` are protected and cannot be extracted.
    ///
    /// Only the :sol:func:`msig` account will be able to call this function successfully.
    function lift() external onlyMsig {
        uint256 amount = address(this).balance;
        // Underflow should never happen and is handled by SafeMath if it does.
        pendingWithdrawals[msg.sender] = amount - usersEthBalance;
    }

    // Transfer asset from one account to another.
    function transferAsset(
        Component memory _comp,
        address _from,
        address _to
    ) internal {
        // All component checks were conducted before.
        if (_comp.assetType == ERC1155_ASSET) {
            IERC1155 nft = IERC1155(_comp.tokenAddress);
            nft.safeBatchTransferFrom(_from, _to, _comp.tokenIds, _comp.amounts, "");
        } else if (_comp.assetType == ERC721_ASSET) {
            IERC721 nft = IERC721(_comp.tokenAddress);
            nft.safeTransferFrom(_from, _to, _comp.tokenIds[0]);
        } else if (_comp.assetType == ERC20_ASSET) {
            IERC20 coin = IERC20(_comp.tokenAddress);
            uint256 amount = _comp.amounts[0];
            if (_from == address(this)) {
                coin.safeTransfer(_to, amount);
            } else {
                coin.safeTransferFrom(_from, _to, amount);
            }
        } else {
            // Ether, single length amounts array was checked before.
            pendingWithdrawals[_to] += _comp.amounts[0];
        }
    }

    // Check asset type and array sizes within a component.
    function checkAsset(Component memory _comp) internal pure returns (uint256) {
        if (_comp.assetType == ERC1155_ASSET) {
            require(
                _comp.tokenIds.length == _comp.amounts.length,
                "TokenIds and amounts len differ"
            );
        } else if (_comp.assetType == ERC721_ASSET) {
            require(_comp.tokenIds.length == 1, "TokenIds array length must be 1");
        } else if (_comp.assetType == ERC20_ASSET) {
            require(_comp.amounts.length == 1, "Amounts array length must be 1");
        } else if (_comp.assetType == ETHER_ASSET) {
            require(_comp.amounts.length == 1, "Amounts array length must be 1");
            return _comp.amounts[0];
        } else {
            revert("Invalid asset type");
        }
        return 0;
    }

    // Check all assets in a component array.
    function checkAssets(Component[] memory _assets) internal pure returns (uint256) {
        uint256 totalEther = 0;
        for (uint256 i = 0; i < _assets.length; i++) {
            totalEther += checkAsset(_assets[i]);
        }
        return totalEther;
    }
}
