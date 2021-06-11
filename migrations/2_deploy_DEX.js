const NFTProtocolDEX = artifacts.require('NFTProtocolDEX');
const ERC20 = artifacts.require('IERC20');

const addresses = require('../.addresses.json');

module.exports = async function(deployer, network, accounts) {
    let NFTProtocolToken = await ERC20.at(addresses[network]['NFT']);
    let multisig = addresses[network]['multisig'];
    let gas = 6000000;

    await deployer.deploy(NFTProtocolDEX, NFTProtocolToken.address, multisig, {gas: gas});

    const dex = await NFTProtocolDEX.deployed();
    console.log("Migration complete. DEX address: " + dex.address);
};
