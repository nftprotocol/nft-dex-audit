const NFTProtocolDEX = artifacts.require('NFTProtocolDEX');
const ERC20 = artifacts.require('IERC20');

module.exports = async function(deployer, network, accounts) {
    let NFTProtocolToken = await ERC20.at("0xcb8d1260f9c92a3a545d409466280ffdd7af7042");
    await deployer.deploy(NFTProtocolDEX, NFTProtocolToken.address, "0x82f06DC2a8e9A265a31C738df9B2F823E67BAF94", {gas: 6000000});

    const dex = await NFTProtocolDEX.deployed();
    console.log("DEX address: " + dex.address);
};
