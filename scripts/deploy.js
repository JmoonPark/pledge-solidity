const hre = require("hardhat");

async function main() {
    // 获取部署者账户
    const [deployer] = await hre.ethers.getSigners();
    console.log("Deploying contracts with the account:", deployer.address)
    // 获取合约工厂(编译后的合约)
    const Lock = await hre.ethers.getContractFactory("Lock");
    // 部署合约
    const lock = await Lock.deploy(1742110855889)
}

// 执行部署
main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });