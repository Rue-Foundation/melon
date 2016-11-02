pragma solidity ^0.4.2;

import "./dependencies/SafeMath.sol";
import "./dependencies/ERC20.sol";
import "./tokens/MelonToken.sol";
import "./tokens/PolkaDotToken.sol";

/// @title Contribution Contract
/// @author Melonport AG <team@melonport.com>
/// @notice This follows Condition-Orientated Programming as outlined here:
/// @notice   https://medium.com/@gavofyork/condition-orientated-programming-969f6ba0161a#.saav3bvva
contract Contribution is SafeMath {

    // FILEDS

    // Constant fields
    uint public constant ETHER_CAP = 1800000 ether; // max amount raised during contribution
    uint public constant ETHER_CAP_LIQUID = ETHER_CAP / 100 * 60; // liquid means tradeable
    uint public constant ETHER_CAP_ICED = ETHER_CAP / 100 * 40; // iced means untradeable untill genesis blk or two years
    uint constant ICED_PRICE = 1125; // One iced tier, remains constant for the duration of the contribution
    uint constant UNIT = 10**3; // MILLI [m], price is divided by this unit, used to avoid decimal numbers

    // Fields that are only changed in constructor
    address public melonport; // All deposited ETH will be instantly forwarded to this address.
    address public parity; // Token allocation for company
    address public btcs; // Bitcoin Suisse allocation option
    address public signer; // signer address see function() {} for comments
    uint public startTime; // contribution start block (set in constructor)
    uint public endTime; // contribution end block (set in constructor)
    MelonToken public melonToken; // Contract of the ERC20 compliant MLNs
    PolkaDotToken public polkaDotToken; // Contract of the ERC20 compliant PDTs

    // Fields that can be changed by functions
    uint public etherRaisedLiquid = 0; // this will keep track of the Ether raised during the contribution
    uint public etherRaisedIced = 0; // this will keep track of the Ether raised during the contribution
    bool public companyAllocated = false; // this will change to true when the company funds are allocated
    bool public halted = false; // the melonport address can set this to true to halt the contribution due to an emergency

    // EVENTS

    event Buy(address indexed sender, uint eth, uint tokens);
    event AllocateCompanyTokens(address indexed sender);

    // MODIFIERS

    modifier is_signer(uint v, bytes32 r, bytes32 s) {
        bytes32 hash = sha256(msg.sender);
        if (ecrecover(hash,v,r,s) != signer) throw;
        _;
    }

    modifier only_melonport {
        if (msg.sender != melonport) throw;
        _;
    }

    modifier only_btcs {
        if (msg.sender != btcs) throw;
        _;
    }

    modifier is_not_halted {
        if (halted) throw;
        _;
    }

    modifier btcs_ether_cap_not_reached {
        if (safeAdd(etherRaisedIced, msg.value) > ETHER_CAP / 100 * 25) throw;
        _;
    }

    modifier liquid_ether_cap_not_reached {
        if (safeAdd(etherRaisedLiquid, msg.value) > ETHER_CAP) throw;
        _;
    }

    modifier iced_ether_cap_not_reached {
        if (safeAdd(etherRaisedIced, msg.value) > ETHER_CAP) throw;
        _;
    }

    modifier msg_value_well_formed {
        if (msg.value < UNIT || msg.value % UNIT != 0) throw;
        _;
    }

    modifier when_company_not_allocated {
        if (companyAllocated) throw;
        _;
    }

    modifier block_timestamp_at_least(uint x) {
        if (!(x <= now)) throw;
        _;
    }

    modifier block_timestamp_at_most(uint x) {
        if (!(now <= x)) throw;
        _;
    }

    // CONSTANT METHODS

    /// Pre: startTime, endTime specified in constructor,
    /// Post: Contribution liquid price in m{MLN+PDT}/ETH, where 1 MLN == 1000 mMLN, 1 PDT == 1000 mPDT
    function price() constant returns(uint)
    {
        // Four liquid tiers
        if (startTime <= now && now < startTime + 2 weeks)
            return 1075;
        if (startTime + 2 weeks <= now && now < startTime + 4 weeks)
            return 1050;
        if (startTime + 4 weeks <= now && now < startTime + 6 weeks)
            return 1025;
        if (startTime + 6 weeks <= now && now < endTime)
            return 1000;
        // Before or after contribution period
        return 0;
    }

    // NON-CONDITIONAL IMPERATIVAL METHODS

    /// Pre: ALL fields, except { melonport, parity, btcs, signer, melonToken, polkaDotToken, startTime } are valid
    /// Post: All fields, including { melonport, parity, btcs, signer, melonToken, polkaDotToken, startTime } are valid
    function Contribution(address melonportInput, address parityInput, address btcsInput, address signerInput, address melonTokenInput, address polkaDotInput, uint startTimeInput) {
        melonport = melonportInput;
        parity = parityInput;
        btcs = btcsInput;
        signer = signerInput;
        startTime = startTimeInput;
        endTime = startTimeInput + 8 weeks;
        // Initialise & Setup Token Contracts
        melonToken = MelonToken(melonTokenInput);
        melonToken.setup(this, startTime);
        polkaDotToken = PolkaDotToken(polkaDotInput);
        polkaDotToken.setup(this, startTime);
    }

    /// Pre: Melonport even before contribution period
    /// Post: Allocate funds of the two companies to their company address.
    function allocateCompanyTokens()
        only_melonport
        when_company_not_allocated
    {
        melonToken.mintIcedToken(melonport, ETHER_CAP * 1200 / 30000); // 12 percent for melonport
        melonToken.mintIcedToken(parity, ETHER_CAP * 300 / 30000); // 3 percent for parity
        polkaDotToken.mintIcedToken(melonport, 2 * ETHER_CAP * 75 / 30000); // 0.75 percent for melonport
        polkaDotToken.mintIcedToken(parity, 2 * ETHER_CAP * 1425 / 30000); // 14.25 percent for parity
        companyAllocated = true;
        AllocateCompanyTokens(msg.sender);
    }

    /// Pre: BTCS even before contribution period, BTCS has exclusiv right to buy up to 25% of all tokens
    ///  msg.value non-zero multiplier of UNIT wei, where 1 wei = 10 ** (-18) ether
    /// Post: BTCS bought MLN and DPT tokens accoriding to ICED_PRICE and msg.value of ICED tranche
    function btcsBuyIced()
        payable
        only_btcs
        block_timestamp_at_most(startTime)
        is_not_halted
        msg_value_well_formed
        btcs_ether_cap_not_reached
    {
        uint tokens = safeMul(msg.value / UNIT, ICED_PRICE);
        melonToken.mintIcedToken(btcs, tokens / 3);
        polkaDotToken.mintIcedToken(btcs, 2 * tokens / 3);
        etherRaisedIced = safeAdd(etherRaisedIced, msg.value);
        if(!melonport.send(msg.value)) throw;
        Buy(btcs, msg.value, tokens);
    }

    /// Pre: Buy entry point, msg.value non-zero multiplier of UNIT wei, where 1 wei = 10 ** (-18) ether
    ///  All contribution depositors must have read and accpeted the legal agreement on https://contribution.melonport.com.
    ///  By doing so they receive the signature sig.v, sig.r and sig.s needed to contribute.
    /// Post: Bought MLN and PDT tokens accoriding to price() and msg.value of LIQUID tranche
    function buyLiquid(uint v, bytes32 r, bytes32 s) payable { buyLiquidRecipient(msg.sender, v, r, s); }

    /// Pre: Generated signature (see Pre: text of buyLiquid()) for a specific address
    /// Post: Bought MLN and PDT tokens on behalf of recipient accoriding to price() and msg.value of LIQUID tranche
    function buyLiquidRecipient(address recipient, uint v, bytes32 r, bytes32 s)
        payable
        is_signer(v, r, s)
        block_timestamp_at_least(startTime)
        block_timestamp_at_most(endTime)
        is_not_halted
        msg_value_well_formed
        liquid_ether_cap_not_reached
    {
        uint tokens = safeMul(msg.value / UNIT, price());
        melonToken.mintLiquidToken(recipient, tokens / 3);
        polkaDotToken.mintLiquidToken(recipient, 2 * tokens / 3);
        etherRaisedLiquid = safeAdd(etherRaisedLiquid, msg.value);
        if(!melonport.send(msg.value)) throw;
        Buy(recipient, msg.value, tokens);
    }

    /// Pre: Generated signature (see Pre: text of buyLiquid())
    /// Post: Bought MLN and DPT tokens accoriding to ICED_PRICE and msg.value of ICED tranche
    function buyIced(uint v, bytes32 r, bytes32 s) payable { buyIcedRecipient(msg.sender, v, r, s); }

    /// Pre: Generated signature (see Pre: text of buyLiquid()) for a specific address
    /// Post: Bought MLN and PDT tokens on behalf of recipient accoriding to ICED_PRICE and msg.value of ICED tranche
    function buyIcedRecipient(address recipient, uint v, bytes32 r, bytes32 s)
        payable
        is_signer(v, r, s)
        block_timestamp_at_least(startTime)
        block_timestamp_at_most(endTime)
        is_not_halted
        msg_value_well_formed
        iced_ether_cap_not_reached
    {
        uint tokens = safeMul(msg.value / UNIT, ICED_PRICE);
        melonToken.mintIcedToken(recipient, tokens / 3);
        polkaDotToken.mintIcedToken(recipient, 2 * tokens / 3);
        etherRaisedIced = safeAdd(etherRaisedIced, msg.value);
        if(!melonport.send(msg.value)) throw;
        Buy(recipient, msg.value, tokens);
    }

    function halt() only_melonport { halted = true; }

    function unhalt() only_melonport { halted = false; }

    function changeFounder(address newFounder) only_melonport { melonport = newFounder; }

}
