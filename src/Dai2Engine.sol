// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions
///////////////////////////////////////////

/*
 * @title DSCEngine
 * @author Patrick Collins
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of
 * all collateral < the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */
//-------------------------
// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Dai2} from "./Dai2.sol";

contract Dai2Engine is ReentrancyGuard {

    //////////////
    //// Errors
    //////////////
    error Dai2Engine__err_MustBeMoreThanZero();
    error Dai2Engine__err_BurnAmountExceedsBalance():
    error Dai2Engine__err_NotZeroAddress():
    error Dai2Engine__err_TokenAddressesAndPriceFeedAddressesMustBeSameLength():
    error Dai2Engine__err_NotAllowedToken():
    error Dai2Engine__err_TransferFailed():
    error Dai2Engine__err_BreaksHealthFactor(uint256 healthFactor);
    error Dai2Engine__MintFailed();
    error Dai2Engine__err_HealthFactorOk();
    error Dai2Engine__err_HealthFactorNotImproved();

    //////////////
    //// Type
    //////////////

    //falta remplezar los latestRoundData() //en chainlink.priceFeed
    //por staleCheckData del contrato custom con la oracleLib
    using OracleLib for AggregatorV3Interface; 

    //////////////
    //// State Variables
    //////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10
    uint256 private constant PRECISION = 1e18
    uint256 private constant LIQUIDATION_THRESHOLD = 50 //%200 overcolalterallized
    uint256 private constant LIQUIDATION_PRECISION = 100 //%200 overcolalterallized
    uint256 private constant LIQUIDATiON_BONUS = 10 //%10 
    uint256 private constant MIN_HEALTH_FACTOR = 1 //

    mapping(address token => address priceFeed) private s_priceFeeds; 
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited; 
    mapping(address user => uint256 amountDai2Minted) private s_Dai2MInted; 
    Dai2 private immutable i_dai2;

    address[] private s_collateralTokens; //weth o wbtc

    //////////////
    //// Events
    //////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount);

    //////////////
    //// Modifiers
    //////////////
    modifier moreThanZero(uint256 amount){
        if(amount == 0) revert Dai2Engine__err_MustBeMoreThanZero;
    }
     modifier isAllowedToken(address token){
        if(s_priceFeeds[token] == address(0)) revert Dai2Engine__err_NotAllowedToken;
    }
    //////////////
    //// Functions
    //////////////
    constructor(
        address[] memory tokenAddresses, 
        address[]memory priceFeedAddresses,
        address dai2Address
    ){
        if(tokenAddresses.length != priceFeedAddresses){
            revert Dai2Engine__err_TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        //ETH/USD ; BTC/USD
        for (uint256 i = 0; i < tokenAddresses.length; i++){
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i]
            s_collateralTokens.push(tokenAddresses[i])
        }

        // i_dai2 = Dai2(dscAddress)
        i_dai2 = Dai2(dai2Address)
    }
    //////////////
    //// External functions
    //////////////

    //CEI => check  effects interaction
    function despositColatteralAndMintDai2(address tokenCollateralAddress, uint256 amountCollateral)
        external
    moreThanZero() isAllowedToken(tokenCollateralAddress) nonReentrant
    {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDai2(amountDai2ToMint);
    }
    function despositColatteral(address tokenCollateralAddress, uint256 amountCollateral)
        external moreThanZero() isAllowedToken(tokenCollateralAddress) nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if(!success){
            revert Dai2Engine__err_TransferFailed();
        }
        //mint Dai2
    }
    /**
     * @param tokenCollateralAddress The collateral address to redeem
     * @param amountCollateral The amount of collateral to redeem
     * @param amountDai2ToBurn 
     * this function burns dai2 and redeems collateral in one TX
     */
    function redeemCollateralForDai2(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDai2ToBurn) 
    external moreThanZero(amountCollateral) {
        //burn debt
        burnDai2(amountDai2ToBurn);
        //recover your collateralized assets
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }
    //CEI, Check Effect, Interaction
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) 
        public  
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function mintDai2(uint256 amountDai2ToMint) external moreThanZero(amountDai2ToMint) {
        s_Dai2MInted[msg.sender] += amountDai2ToMint
        _revertIfHealthFactorIsBroken(msg.sender);

        bool mintSuccess = i.Dai2.mint(msg.sender, amountDai2ToMint);
        if(!mintSuccess) {
            revert(Dai2Engine__err_MintFailed());
        }
            
    }
    function burnDai2(uint256 amount) external moreThanZero(amount) {
        _burnDai2(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); //Probably willl never be used
    }

    /* 
        @param userm, a user who has broken the health factor
        @notice You can partially liquidate a user
        @notice You ll get a liquidation bonuus
        @notice we esteem 200% of collateral
    */
    function liquidate(address collateralToken, address user, uint256 debtToCover) external moreThanZero(debtToCover) nonReentrant {
        uint256 initialHealth = _healthFactor(user);
        if(initialHealth >= MIN_HEALTH_FACTOR) {
            revert Dai2Engine__err_HealthFactorOk()
        }

        uint256 tokenRecoveredFromDebt = getTokenAmountFromUsd(collateralToken, debtToCover);
        // 10% bonus for rescuing debt
        uint256 reward = (tokenRecoveredFromDebt * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION 
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + reward;
        _redeemCollateralForDai2(user, msg.sender, collateralToken, totalCollateralToRedeem);
        //burn
        _burnDai2(debtToCover, user, msg.sender);

        uint256 finalHealth = _healthFactor(user);
        if (finalHealth <= initialHealth){
            revert Dai2Engine__err_HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }   
    
    function getHealthFactor() external {

    } 
    
    //////////////
    //// Private & internal view functions
    //////////////
    function _getAccountInformation(address user) 
    private view returns (uint256 totalDai2Minted, uint256 collateralValueInUsd){
        totalDai2Minted = s_Dai2Minted[user]; 
        collateralValueInUsd = getAccountCollateralValueInUsd(user); 
    }
    //thrshold is 50 => you MUST hace DOUBLE the collateral
        // => you use 500usd(eth) to take you need 100usd(eth) min. to mint 50dai2
        // => if eth value drops 50% => 
    function _healthFactor(address user) private view returns (uint256){
        //total Dai2 minted
        //total collateral VAL
        (uint256 totalDai2Minted, uint256 collateralValueInUsd) = _getAccountInformation(user)
        uint256 collateralAdjusted = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return ( collateralAdjustedForThreshold * PRECISION)
    }
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor= _healthFactor(user);

        bool isUnderCollateralized = userHealthFactor < MIN_HEALTH_FACTOR

        if(isUnderCollateralized){
            revert Dai2Engine__err_BreaksHealthFactor(userHealthFactor);
        }
        
    }
    function redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral) 
        internal  
        moreThanZero(amountCollateral)
        nonReentrant
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, amountCollateral, tokenCollateralAddress);
        // _calculateHealthFactorAfter();

        //contract pays user/user 
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if(!success) {
            revert Dai2Engine__err_TransferFailed();
        }
    }
    function _burnDai2(uint256 amount, address onBehalfOf, address dai2From) external moreThanZero(amount) {
        s_Dai2Minted[onBehalfOf] -= amount;
        bool success = i_dai2.transferFrom(dai2From, address(this), amount);
        if(!success){
            revert Dai2Engine__err_TransferFailed();
        }

        i_dai2.burn(amount);
    }
    //////////////
    //// Public & External view functions
    //////////////
    function getAccountCollateralValueInUsd(address user) public view returns(uint256 totalCollateralValueInUsd){
        for (uint256 i = 0; i < s_collateralTokens.length; i++){
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd

    }
    function getUsdValue(address token, uint256 amount) public view returns(uint256) {
        AggregatorV3Interface usdPriceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price...) = usdPriceFeed.latestRoundData();                               //ex. $4032 (el ETH)

        //price * amount & formatting
        uint256 formattedPrice = (uint256(price) * ADDITIONAL_FEED_PRECISION) * amount //ex. (uint256(2241) * 1e10) * 500;

        return formattedPrice / PRECISION;                                             // 1.1205e16 / 1e18 = 11205
    }
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns(uint256) {
        AggregatorV3Interface usdPriceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price...) = usdPriceFeed.latestRoundData();                               

        //price * amount & formatting
        uint256 formattedUSD = (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION); 

        return formattedUSD;
    }
}
























/*
    pragma solidity 0.8.19;

    import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";
    import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
    import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

    import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
    contract DSCEngine is ReentrancyGuard {
        ///////////////////
        // Errors
        ///////////////////
        error DSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch();
        error DSCEngine__NeedsMoreThanZero();
        error DSCEngine__TokenNotAllowed(address token);
        error DSCEngine__TransferFailed();
        error DSCEngine__BreaksHealthFactor(uint256 healthFactorValue);
        error DSCEngine__MintFailed();
        error DSCEngine__HealthFactorOk();
        error DSCEngine__HealthFactorNotImproved();

        ///////////////////
        // Types
        ///////////////////
        using OracleLib for AggregatorV3Interface;

        ///////////////////
        // State Variables
        ///////////////////
        DecentralizedStableCoin private immutable i_dsc;

        uint256 private constant LIQUIDATION_THRESHOLD = 50; // This means you need to be 200% over-collateralized
        uint256 private constant LIQUIDATION_BONUS = 10; // This means you get assets at a 10% discount when liquidating
        uint256 private constant LIQUIDATION_PRECISION = 100;
        uint256 private constant MIN_HEALTH_FACTOR = 1e18;
        uint256 private constant PRECISION = 1e18;
        uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
        uint256 private constant FEED_PRECISION = 1e8;

        /// @dev Mapping of token address to price feed address
        mapping(address collateralToken => address priceFeed) private s_priceFeeds;
        /// @dev Amount of collateral deposited by user
        mapping(address user => mapping(address collateralToken => uint256 amount)) private s_collateralDeposited;
        /// @dev Amount of DSC minted by user
        mapping(address user => uint256 amount) private s_DSCMinted;
        /// @dev If we know exactly how many tokens we have, we could make this immutable!
        address[] private s_collateralTokens;

        ///////////////////
        // Events
        ///////////////////
        event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
        event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount); // if redeemFrom != redeemedTo, then it was liquidated

        ///////////////////
        // Modifiers
        ///////////////////
        modifier moreThanZero(uint256 amount) {
            if (amount == 0) {
                revert DSCEngine__NeedsMoreThanZero();
            }
            _;
        }

        modifier isAllowedToken(address token) {
            if (s_priceFeeds[token] == address(0)) {
                revert DSCEngine__TokenNotAllowed(token);
            }
            _;
        }

        ///////////////////
        // Functions
        ///////////////////
        constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
            if (tokenAddresses.length != priceFeedAddresses.length) {
                revert DSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch();
            }
            // These feeds will be the USD pairs
            // For example ETH / USD or MKR / USD
            for (uint256 i = 0; i < tokenAddresses.length; i++) {
                s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
                s_collateralTokens.push(tokenAddresses[i]);
            }
            i_dsc = DecentralizedStableCoin(dscAddress);
        }

        ///////////////////
        // External Functions
        ///////////////////
    
        function depositCollateralAndMintDsc(
            address tokenCollateralAddress,
            uint256 amountCollateral,
            uint256 amountDscToMint
        ) external {
            depositCollateral(tokenCollateralAddress, amountCollateral);
            mintDsc(amountDscToMint);
        }

        function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
            external
            moreThanZero(amountCollateral)
            isAllowedToken(tokenCollateralAddress)
        {
            _burnDsc(amountDscToBurn, msg.sender, msg.sender);
            _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
            revertIfHealthFactorIsBroken(msg.sender);
        }

        * @param tokenCollateralAddress: The ERC20 token address of the collateral you're redeeming
        * @param amountCollateral: The amount of collateral you're redeeming
        * @notice This function will redeem your collateral.
        * @notice If you have DSC minted, you will not be able to redeem until you burn your DSC
        function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
            external
            moreThanZero(amountCollateral)
            nonReentrant
            isAllowedToken(tokenCollateralAddress)
        {
            _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
            revertIfHealthFactorIsBroken(msg.sender);
        }

        * @notice careful! You'll burn your DSC here! Make sure you want to do this...
        * @dev you might want to use this if you're nervous you might get liquidated and want to just burn
        * you DSC but keep your collateral in.
        function burnDsc(uint256 amount) external moreThanZero(amount) {
            _burnDsc(amount, msg.sender, msg.sender);
            revertIfHealthFactorIsBroken(msg.sender); // I don't think this would ever hit...
        }

        * @param collateral: The ERC20 token address of the collateral you're using to make the protocol solvent again.
        * This is collateral that you're going to take from the user who is insolvent.
        * In return, you have to burn your DSC to pay off their debt, but you don't pay off your own.
        * @param user: The user who is insolvent. They have to have a _healthFactor below MIN_HEALTH_FACTOR
        * @param debtToCover: The amount of DSC you want to burn to cover the user's debt.
        *
        * @notice: You can partially liquidate a user.
        * @notice: You will get a 10% LIQUIDATION_BONUS for taking the users funds.
        * @notice: This function working assumes that the protocol will be roughly 150% overcollateralized in order for this to work.
        * @notice: A known bug would be if the protocol was only 100% collateralized, we wouldn't be able to liquidate anyone.
        * For example, if the price of the collateral plummeted before anyone could be liquidated.
        function liquidate(address collateral, address user, uint256 debtToCover)
            external
            moreThanZero(debtToCover)
            nonReentrant
        {
            uint256 startingUserHealthFactor = _healthFactor(user);
            if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
                revert DSCEngine__HealthFactorOk();
            }
            // If covering 100 DSC, we need to $100 of collateral
            uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
            // And give them a 10% bonus
            // So we are giving the liquidator $110 of WETH for 100 DSC
            // We should implement a feature to liquidate in the event the protocol is insolvent
            // And sweep extra amounts into a treasury
            uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
            // Burn DSC equal to debtToCover
            // Figure out how much collateral to recover based on how much burnt
            _redeemCollateral(collateral, tokenAmountFromDebtCovered + bonusCollateral, user, msg.sender);
            _burnDsc(debtToCover, user, msg.sender);

            uint256 endingUserHealthFactor = _healthFactor(user);
            // This conditional should never hit, but just in case
            if (endingUserHealthFactor <= startingUserHealthFactor) {
                revert DSCEngine__HealthFactorNotImproved();
            }
            revertIfHealthFactorIsBroken(msg.sender);
        }

    
        function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
            s_DSCMinted[msg.sender] += amountDscToMint;
            revertIfHealthFactorIsBroken(msg.sender);
            bool minted = i_dsc.mint(msg.sender, amountDscToMint);

            if (minted != true) {
                revert DSCEngine__MintFailed();
            }
        }

        function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
            public
            moreThanZero(amountCollateral)
            nonReentrant
            isAllowedToken(tokenCollateralAddress)
        {
            s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
            emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
            bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
            if (!success) {
                revert DSCEngine__TransferFailed();
            }
        }

        ///////////////////
        // Private Functions
        ///////////////////
        function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
            private
        {
            s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
            emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
            bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
            if (!success) {
                revert DSCEngine__TransferFailed();
            }
        }

        function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
            s_DSCMinted[onBehalfOf] -= amountDscToBurn;

            bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
            // This conditional is hypothetically unreachable
            if (!success) {
                revert DSCEngine__TransferFailed();
            }
            i_dsc.burn(amountDscToBurn);
        }

        //////////////////////////////
        // Private & Internal View & Pure Functions
        //////////////////////////////

        function _getAccountInformation(address user)
            private
            view
            returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
        {
            totalDscMinted = s_DSCMinted[user];
            collateralValueInUsd = getAccountCollateralValue(user);
        }

        function _healthFactor(address user) private view returns (uint256) {
            (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
            return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
        }

        function _getUsdValue(address token, uint256 amount) private view returns (uint256) {
            AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
            (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
            // 1 ETH = 1000 USD
            // The returned value from Chainlink will be 1000 * 1e8
            // Most USD pairs have 8 decimals, so we will just pretend they all do
            // We want to have everything in terms of WEI, so we add 10 zeros at the end
            return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
        }

        function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
            internal
            pure
            returns (uint256)
        {
            if (totalDscMinted == 0) return type(uint256).max;
            uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
            return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
        }

        function revertIfHealthFactorIsBroken(address user) internal view {
            uint256 userHealthFactor = _healthFactor(user);
            if (userHealthFactor < MIN_HEALTH_FACTOR) {
                revert DSCEngine__BreaksHealthFactor(userHealthFactor);
            }
        }

        ////////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////
        // External & Public View & Pure Functions
        ////////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////
        function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
            external
            pure
            returns (uint256)
        {
            return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
        }

        function getAccountInformation(address user)
            external
            view
            returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
        {
            return _getAccountInformation(user);
        }

        function getUsdValue(
            address token,
            uint256 amount // in WEI
        ) external view returns (uint256) {
            return _getUsdValue(token, amount);
        }

        function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
            return s_collateralDeposited[user][token];
        }

        function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
            for (uint256 index = 0; index < s_collateralTokens.length; index++) {
                address token = s_collateralTokens[index];
                uint256 amount = s_collateralDeposited[user][token];
                totalCollateralValueInUsd += _getUsdValue(token, amount);
            }
            return totalCollateralValueInUsd;
        }

        function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
            AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
            (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
            // $100e18 USD Debt
            // 1 ETH = 2000 USD
            // The returned value from Chainlink will be 2000 * 1e8
            // Most USD pairs have 8 decimals, so we will just pretend they all do
            return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
        }

        function getPrecision() external pure returns (uint256) {
            return PRECISION;
        }

        function getAdditionalFeedPrecision() external pure returns (uint256) {
            return ADDITIONAL_FEED_PRECISION;
        }

        function getLiquidationThreshold() external pure returns (uint256) {
            return LIQUIDATION_THRESHOLD;
        }

        function getLiquidationBonus() external pure returns (uint256) {
            return LIQUIDATION_BONUS;
        }

        function getLiquidationPrecision() external pure returns (uint256) {
            return LIQUIDATION_PRECISION;
        }

        function getMinHealthFactor() external pure returns (uint256) {
            return MIN_HEALTH_FACTOR;
        }

        function getCollateralTokens() external view returns (address[] memory) {
            return s_collateralTokens;
        }

        function getDsc() external view returns (address) {
            return address(i_dsc);
        }

        function getCollateralTokenPriceFeed(address token) external view returns (address) {
            return s_priceFeeds[token];
        }

        function getHealthFactor(address user) external view returns (uint256) {
            return _healthFactor(user);
        }
    }





  */
