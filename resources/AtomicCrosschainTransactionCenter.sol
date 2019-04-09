pragma solidity ^0.5.2;


import "./Aurrency.sol";
import "./TokenController.sol";
import "./openzeppelin-solidity/contracts/ownership/Ownable.sol";

/// @title AtomicCrosschainTransactionCenter contract provides interface with transfer transaction. Contract implements initiation and validation of transactions.

contract AtomicCrosschainTransactionCenter is Ownable
{
    enum TransferState
    {
        Initiated,
        Accepted,
        Banned,
        Expired,
        Ignored,
        Finished
    }

    enum HashType
    {
        SHA256,
        RIPEMD160,
        KECCAK256
    }

    struct CrosschainAtomicTransfer
    {
        uint initTimestamp;
        address initiator;

        string secret;
        bytes32 secretHash;
        HashType hashType;

        string sourceLedger;
        string destinationLedger;

        bool emptied;
        bool isDestination;
        uint value;

        TransferState state;
        uint acceptionTimestamp;
    }

    /// @notice Transaction has been initiated
    event Initiated(address indexed initiator, uint timestamp, bytes32 secretHash, uint value, bool isDestination, HashType hashType, string sourceLedger, string destinationLedger);

    /// @notice Transaction has been accepted
    event Accepted(uint timestamp, bytes32 secretHash);

    /// @notice Transaction has been banned
    event Banned(bytes32 secretHash);

    /// @notice Transaction has been redeemed
    event Redeemed(string secret, bytes32 secretHash);

    /// @notice Transaction has been recalled
    event Refunded(bytes32 secretHash);

    /// @notice Contract initialization
    /// @param _controller Deployed token controller contract address
    /// @param _timeoutPerHoldingTransfer Maximum time amount for which transaction is to be finished after initialization
    /// @param _timeToRedeemAfterAcception Maximum time amount for which transaction can be banned after acception
    /// @param _timeoutAfterAcception Maximum time amount for which transaction is to be finished after acception
    /// @param _timeoutToIgnoreTransfer Minimum time amount for which transaction becomes ignored if it is not accepted or banned 
    constructor(address _controller,
        uint _timeoutPerHoldingTransfer,
        uint _timeToRedeemAfterAcception,
        uint _timeoutAfterAcception,
        uint _timeoutToIgnoreTransfer,
        uint _fee) Ownable() public
    {
        require(_timeToRedeemAfterAcception < _timeoutAfterAcception);
        require(_timeoutToIgnoreTransfer + _timeoutAfterAcception < _timeoutPerHoldingTransfer);

        controller = _controller;
        initiationEnabled = true;

        feePerTransfer = _fee;

        timeoutPerHoldingTransfer = _timeoutPerHoldingTransfer;
        timeToRedeemAfterAcception = _timeToRedeemAfterAcception;
        timeoutAfterAcception = _timeoutAfterAcception;
        timeoutToIgnoreTransfer = _timeoutToIgnoreTransfer;     
    }

    /// @notice Accepting transaction by contract owner
    /// @param _secretHash Transaction secret hash
    function accept(bytes32 _secretHash) onlyOwner() public
    {   
        require(transfers[_secretHash].state == TransferState.Initiated);       // by default initiated
        require(transfers[_secretHash].isDestination == true);                  

        if (transfers[_secretHash].state == TransferState.Initiated
            && block.timestamp - transfers[_secretHash].initTimestamp > timeoutToIgnoreTransfer)
        {
            transfers[_secretHash].state = TransferState.Ignored;
            return;
        }

        transfers[_secretHash].state = TransferState.Accepted;
        transfers[_secretHash].acceptionTimestamp = block.timestamp;

        emit Accepted(block.timestamp, _secretHash);
    }

    /// @notice Banning transaction by contract owner
    /// @param _secretHash Transaction secret hash
    function ban(bytes32 _secretHash) onlyOwner() public
    {
        require(transfers[_secretHash].state == TransferState.Accepted);
        require(transfers[_secretHash].isDestination == true);

        transfers[_secretHash].state = TransferState.Banned;

        emit Banned(_secretHash);
    }

    /// @notice Setting new value of initiation ability of new crosschain transfers by contract owner
    /// @param status New status
    function setInitiationEnabled(bool status) onlyOwner() public
    {
        initiationEnabled = status;
    }

    /// @notice Initialization new transfer transaction 
    /// @param _secretHash Transaction secret hash
    /// @param _value Transfer token amount
    /// @param _isDestination In case it's true transaction mints tokens to initiator address else transaction burns tokens after transfer finishing. 
    /// @param _type Hash-function used for secret hashing type
    /// @param _sourceLedger Source ledger ticker
    /// @param _destinationLedger Destination ledger ticker
    function initiateCrosschainAtomicTransfer(bytes32 _secretHash, uint _value, bool _isDestination, HashType _type, string _sourceLedger, string _destinationLedger) public
    {
        require(_value > 0);
        require(initiationEnabled == true);
        require(transfers[_secretHash].initiator == address(0));

        if (!_isDestination)
        {
            holdTokens(msg.sender, _value);
        }

        transfers[_secretHash].initTimestamp = block.timestamp;
        transfers[_secretHash].initiator = msg.sender;

        transfers[_secretHash].secretHash = _secretHash;
        transfers[_secretHash].hashType = _type;

        transfers[_secretHash].sourceLedger = _sourceLedger;
        transfers[_secretHash].destinationLedger = _destinationLedger;

        transfers[_secretHash].emptied = false;
        transfers[_secretHash].isDestination = _isDestination;
        transfers[_secretHash].value = _value;

        transfers[_secretHash].state = TransferState.Initiated; // It is already initiated!

        emit Initiated(msg.sender, block.timestamp, _secretHash, _value, _isDestination, _type, _sourceLedger, _destinationLedger);
    }

    function setFeeGetter(address newGetter) external onlyOwner()
    {
        feeGetter = newGetter;
    }

    /// @notice Disclosure transaction secret to finish token transferring (NOTE: Early dusclosure doesn't lead to finish transferring. It may be unsafe) 
    /// @param _secret Transaction secret as base of secret hash
    /// @param _secretHash Transaction secret hash
    function redeem(string _secret, bytes32 _secretHash) public
    {
        if (transfers[_secretHash].isDestination)
            mintForUnholdingTransfer(_secret, _secretHash);
        else
            burnForHoldingTransfer(_secret, _secretHash);

        transfers[_secretHash].secret = _secret;

        emit Redeemed(_secret, _secretHash);
    }

    /// @notice Returning holding tokens to initiator if transaction is epxired
    /// @param _secretHash Transaction secret hash
    function refund(bytes32 _secretHash) public
    {
        checkExpirationAndSetState(_secretHash);

        require(transfers[_secretHash].state == TransferState.Expired);
        require(transfers[_secretHash].isDestination == false);
        require(transfers[_secretHash].emptied == false);

        transfers[_secretHash].emptied = true;

        address token = TokenController(controller).token();
        Aurrency(token).transfer(transfers[_secretHash].initiator, transfers[_secretHash].value);

        //emit Refunded(_secretHash);
    }

    /// @notice Checking the matching secret to hash  
    /// @param _secret Transaction secret as base of secret hash
    /// @param _secretHash Transaction secret hash
    /// @return Matching result
    function isSecretValid(string _secret, bytes32 _secretHash) public view returns (bool)
    {
        if (transfers[_secretHash].hashType == HashType.SHA256)
            return sha256(_secret) == _secretHash;

        if (transfers[_secretHash].hashType == HashType.RIPEMD160)
            return bytes32(ripemd160(_secret)) == _secretHash;

        if (transfers[_secretHash].hashType == HashType.KECCAK256)
            return bytes32(keccak256(_secret)) == _secretHash;

        return false;
    }

    function getInitTimestamp(bytes32 _secretHash) public view returns (uint)
    {
        return transfers[_secretHash].initTimestamp;
    }

    function getInitiator(bytes32 _secretHash) public view returns (address)
    {
        return transfers[_secretHash].initiator;
    }

    function getSecret(bytes32 _secretHash) public view returns (string)
    {
        return transfers[_secretHash].secret;
    }

    function getHashType(bytes32 _secretHash) public view returns (HashType)
    {
        return transfers[_secretHash].hashType;
    }

    function getIsDestination(bytes32 _secretHash) public view returns (bool)
    {
        return transfers[_secretHash].isDestination;
    }

    function getValue(bytes32 _secretHash) public view returns (uint)
    {
        return transfers[_secretHash].value;
    }

    function getState(bytes32 _secretHash) public view returns (TransferState)
    {
        return transfers[_secretHash].state;
    }

    function getAcceptionTimestamp(bytes32 _secretHash) public view returns (uint)
    {
        return transfers[_secretHash].acceptionTimestamp;
    }

    function getSourceLedger(bytes32 _secretHash) public view returns (string)
    {
        return transfers[_secretHash].sourceLedger;
    }

    function getDestinationLedger(bytes32 _secretHash) public view returns (string)
    {
        return transfers[_secretHash].destinationLedger;
    }

    /// @notice Holding tokens on address with transfer from.
    /// @param from Transfer address
    /// @param _value Transfer token amount
    function holdTokens(address from, uint _value) internal 
    {
        address token = TokenController(controller).token();
        require(Aurrency(token).allowance(from, this) >= _value);

        Aurrency(token).transferFrom(from, this, _value);
    }

    /// @notice Checking time expiration and set expired transaction state if true.
    /// @param _secretHash Transaction secret hash
    /// @return True if time is over
    function checkExpirationAndSetState(bytes32 _secretHash) internal returns (bool)
    {
        if (transfers[_secretHash].state == TransferState.Finished)
            return false;

        if (transfers[_secretHash].isDestination == true)
            return false;

        if (block.timestamp - transfers[_secretHash].initTimestamp > timeoutPerHoldingTransfer)
        {
            transfers[_secretHash].state = TransferState.Expired;
            return true;
        }

        return false;
    }

    /// @notice Burning tokens to transaction initiator address
    /// @param _secret Transaction secret as base of secret hash
    /// @param _secretHash Transaction secret hash
    function burnForHoldingTransfer(string _secret, bytes32 _secretHash) internal  
    {
        if (checkExpirationAndSetState(_secretHash))
            return;

        require(isSecretValid(_secret, _secretHash));
        require(transfers[_secretHash].state == TransferState.Initiated);

        transfers[_secretHash].state = TransferState.Finished;

        address token = TokenController(controller).token();
        Aurrency(token).burn(transfers[_secretHash].value);
    }

    /// @notice Minting tokens to transaction initiator address
    /// @param _secret Transaction secret as base of secret hash
    /// @param _secretHash Transaction secret hash
    function mintForUnholdingTransfer(string _secret, bytes32 _secretHash) internal 
    {
        if (transfers[_secretHash].state == TransferState.Initiated
            && block.timestamp - transfers[_secretHash].initTimestamp > timeoutToIgnoreTransfer)
        {
            transfers[_secretHash].state = TransferState.Ignored;
            return;
        }
 
        require(isSecretValid(_secret, _secretHash));
        require(feePerTransfer <= transfers[_secretHash].value);
        require(transfers[_secretHash].state == TransferState.Accepted);
        require(block.timestamp - transfers[_secretHash].acceptionTimestamp > timeToRedeemAfterAcception);

        if (block.timestamp - transfers[_secretHash].acceptionTimestamp > timeoutAfterAcception)
        {
            transfers[_secretHash].state = TransferState.Expired;
            return;
        }

        transfers[_secretHash].state = TransferState.Finished;

        TokenController(controller).mint(transfers[_secretHash].initiator, transfers[_secretHash].value - feePerTransfer);
        TokenController(controller).mint(feeGetter, feePerTransfer);
    }

    /// @notice Status of new transfer inititation ability 
    bool public initiationEnabled;

    /// @notice TokenController contract address
    address public controller;

    /// @notice Maximum time amount for which transaction is to be finished after initialization
    uint public timeoutPerHoldingTransfer;

    /// @notice Maximum time amount for which transaction can be banned after acception
    uint public timeToRedeemAfterAcception;

    /// @notice Maximum time amount for which transaction is to be finished after acception
    uint public timeoutAfterAcception;

    /// @notice Minimum time amount for which transaction becomes ignored if it is not accepted or banned
    uint public timeoutToIgnoreTransfer;

    uint public feePerTransfer;

    address public feeGetter;

    /// @notice Transfer mapping
    mapping (bytes32 => CrosschainAtomicTransfer) public transfers;
}
