const { ethers, upgrades } = require("hardhat");
require("dotenv").config({ path: "../.env" });

async function main() {
  const [deployer, PropertyManager, ...addrs] = await ethers.getSigners();
  const DAO = await ethers.getContractFactory("DAO");
  console.log("Deploying from account ", deployer.address);
  const dao = await upgrades.upgradeProxy("0x9666290621041C4F9fe1E2a9CBF2d40cf9D7f6da",DAO,{ kind: "uups" })
  // const dao = await upgrades.deployProxy(
  //   DAO,
  //   [
  //     process.env.VOTING_DELAY,
  //     process.env.VOTING_PERIOD,
  //     process.env.PROPERTY_MANAGER,
  //   ],
  //   {
  //     initializer: "initialize",
  //   },
  //   { kind: "uups" }
  // );
  // await dao.deployed();
  // console.log("Dao deployed at", dao.address);
  console.log("Dao upgraded at", dao.address);
}
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
