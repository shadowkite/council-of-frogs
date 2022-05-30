// SPDX-License-Identifier: Unlicensed
pragma solidity =0.8.9;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@dea-sg/layerzero/contracts/interfaces/ILayerZeroEndpoint.sol";
import "@dea-sg/layerzero/contracts/interfaces/ILayerZeroReceiver.sol";
import "./NonblockingReceiver.sol";

contract x0C0F_CongressionalOffice is ERC721Enumerable, Ownable, NonblockingReceiver {
    using SafeMath for uint256;
    using Strings for uint256;

    event BridgeRequest(address receiver, uint16 target, uint256 tokenId);
    event ReceiveNFT(uint16 _srcChainId, address _from, uint256 _tokenId);

    string public baseURI;

    /** Mint settings **/
    uint256 public normalCost;
    uint256 public discountedCost;
    bool public mintPaused = true;

    // Random index assignment
    uint256 public constant TOKEN_LIMIT = 2500;
    uint256 internal nonce = 0;
    uint256[TOKEN_LIMIT] internal indices;
    uint256 public mintedSupply = 0;

    /** Bridger wallet **/
    address public bridger;

    /** Project bridge **/
    bool public projectTraverseEnabled = false;
    mapping(bytes32 => bool) public handledMessages;
    mapping(uint16 => uint256) public gasCosts;

    // LayerZero
    uint256 lzGas = 350000;

    constructor() ERC721('Council of Frogs', 'C0F') {}

    /** Adoption papers **/
    function mint(uint256 _mintAmount) public payable {
        require(_mintAmount > 0, 'Congressional Office: What? Adopt us. Please.');
        require(_mintAmount <= 20, 'Congressional Office: Gas is expensive these days.');
        require(mintedSupply.add(_mintAmount) <= TOKEN_LIMIT, 'Congressional Office: Our chairs are already empty :(');
        require(!mintPaused, 'Congressional Office: Hold up.');

        if (msg.sender != owner()) {
            uint256 cost = getCostsforUser();
            require(msg.value >= cost.mul(_mintAmount), 'Congressional Office: Send more. Tax is not enough to pay off the debt collectors.');
        }

        for (uint256 i = 1; i <= _mintAmount; i++) {
            uint256 id = randomIndex();
            mintedSupply = mintedSupply.add(1);
            _safeMint(msg.sender, id);
        }
    }

    function getCostsforUser() public view returns(uint256) {
        IERC721 ratsContract = IERC721(0xD27CFd5b254E8D958c0c8e7f99E17A1e33652C1A);
        if(ratsContract.balanceOf(msg.sender) > 0) {
            return discountedCost;
        }
        return normalCost;
    }

    function setCost(uint256 _newCost, uint256 _discountedCost) public onlyOwner {
        normalCost = _newCost;
        discountedCost = _discountedCost;
    }

    function randomIndex() internal returns (uint256) {
        uint256 totalSize = TOKEN_LIMIT - mintedSupply;
        uint256 index = uint256(
            keccak256(
                abi.encodePacked(
                    nonce,
                    msg.sender,
                    block.difficulty,
                    block.timestamp
                )
            )
        ) % totalSize;

        uint256 value = 0;
        if (indices[index] != 0) {
            value = indices[index];
        } else {
            value = index;
        }

        if (indices[totalSize - 1] == 0) {
            indices[index] = totalSize - 1;
        } else {
            indices[index] = indices[totalSize - 1];
        }
        nonce++;
        return value.add(1);
    }

    /** Views **/
    function walletOfOwner(address _owner) public view returns (uint256[] memory) {
        uint256 ownerTokenCount = balanceOf(_owner);
        uint256[] memory tokenIds = new uint256[](ownerTokenCount);
        for (uint256 i; i < ownerTokenCount; i++) {
            tokenIds[i] = tokenOfOwnerByIndex(_owner, i);
        }
        return tokenIds;
    }

    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        require(_exists(tokenId), "ERC721Metadata: URI query for nonexistent token");
        string memory currentBaseURI = _baseURI();
        return bytes(currentBaseURI).length > 0 ? string(abi.encodePacked(currentBaseURI, tokenId.toString(), '.json')) : "";
    }

    function _baseURI() internal view virtual override returns (string memory) {
        return baseURI;
    }

    /** Owner of the congress decisions **/
    function bridgerAddress(address _bridger) external onlyOwner {
        bridger = _bridger;
    }

    function setBaseURI(string memory _base) external onlyOwner {
        baseURI = _base;
    }

    function setEndpoint(address _endpoint) public onlyOwner {
        endpoint = ILayerZeroEndpoint(_endpoint);
    }

    function setGas(uint256 _gas) public onlyOwner {
        lzGas = _gas;
    }

    function setPauseMint(bool _paused) public onlyOwner {
        mintPaused = _paused;
    }

    function setGasCosts(uint16 _target, uint256 _gas) public onlyOwner {
        gasCosts[_target] = _gas;
    }

    function setProjectTraverseEnabled(bool _enabled) public onlyOwner {
        projectTraverseEnabled = _enabled;
    }

    function withdraw() public payable onlyOwner {
        (bool os, ) = payable(msg.sender).call{value: address(this).balance}("");
        require(os);
    }

    /* BCH Bridge */
    function projectTraverseChains(uint16 _target, uint256 _tokenId) public payable {
        require(projectTraverseEnabled != false, "Project traverse route disabled");
        require(msg.sender == ownerOf(_tokenId), "Not owner");
        require(gasCosts[_target] <= msg.value, "Not enough gas");

        _burn(_tokenId);
        emit BridgeRequest(msg.sender, _target, _tokenId);
    }

    function projectReceive(bytes32 _msgId, address _receiver, uint256 _tokenId) public {
        require(msg.sender == bridger, 'You are not a bridger');
        require(!handledMessages[_msgId], 'Already handled');

        handledMessages[_msgId] = true;
        _mint(_receiver, _tokenId);
    }

    /* Layer Zero */
    function traverseChains(uint16 _dstChainId, uint256 _tokenId) public payable {
        require(msg.sender == ownerOf(_tokenId), "Not the owner");
        _burn(_tokenId);

        bytes memory payload = abi.encode(msg.sender, _tokenId);
        uint16 version = 1;
        bytes memory adapterParams = abi.encodePacked(version, lzGas);
        (uint256 messageFee, ) = endpoint.estimateFees(_dstChainId, address(this), payload, false, adapterParams);

        require(msg.value >= messageFee, "Must send enough value to cover messageFee");
        endpoint.send{value: msg.value}(_dstChainId, trustedRemoteLookup[_dstChainId], payload, payable(msg.sender), address(0x0), adapterParams);
    }

    function _LzReceive(uint16 _srcChainId, bytes memory, uint64, bytes memory _payload) internal override {
        (address toAddress, uint256 tokenId) = abi.decode(_payload, (address, uint256));
        _safeMint(toAddress, tokenId);
        emit ReceiveNFT(_srcChainId, toAddress, tokenId);
    }

    function estimateFees(uint16 _dstChainId, address _userApplication, bytes calldata _payload, bool _payInZRO, bytes calldata _adapterParams) external view returns (uint256 nativeFee, uint256 zroFee) {
        return endpoint.estimateFees(
            _dstChainId,
            _userApplication,
            _payload,
            _payInZRO,
            _adapterParams
        );
    }
}