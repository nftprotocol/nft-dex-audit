# NFT DEX

https://nft-dex.org

## Get started

Install:
```
npm i
```

Deploy contracts on ganache mainnet fork:
```
rpc="wss://mainnet.infura.io/ws/v3/..."
mnemonic="correct horse battery staple..."
./node_modules/.bin/ganache-cli -f "$rpc" -m "$mnemonic"
npx truffle migrate --network development --reset
```

Documentation:
```
open docs/html/index.html
```
