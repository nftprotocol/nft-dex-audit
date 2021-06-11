const HDWalletProvider = require('@truffle/hdwallet-provider');
//const { infura, mnemonic } = require('./.secrets.json');

module.exports = {
  networks: {
    development: {
      protocol: 'http',
      host: 'localhost',
      port: 8545,
      gasPrice: 1e9,
      gas: 4000000,
      networkId: '*',
      network_id: '*'
    }
  },
  plugins: ["solidity-coverage"],
  compilers: {
    solc: {
      version: "0.8.4",
      "settings": {
        optimizer: {
          enabled: true,
          runs: 200
        }
      }
    }
  }
};
