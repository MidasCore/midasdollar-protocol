import { Block, JsonRpcProvider } from "@ethersproject/providers";
import { Contract, BigNumber, BigNumberish, utils } from "ethers";
import AllBigNumber from "bignumber.js";

export const ADDRESS_ZERO = "0x0000000000000000000000000000000000000000";
export const AddressZero = "0x0000000000000000000000000000000000000000";
export const maxUint256 = BigNumber.from(2).pow(256).sub(1);
export const maxInt128 = BigNumber.from(2).pow(128).sub(1);

export async function advanceTime(provider: JsonRpcProvider, time: number): Promise<void> {
  return provider.send("evm_increaseTime", [time]);
}

export async function advanceBlock(provider: JsonRpcProvider): Promise<Block> {
  await provider.send("evm_mine", []);
  return await provider.getBlock("latest");
}

export async function advanceTimeAndBlock(provider: JsonRpcProvider, time: number): Promise<Block> {
  await advanceTime(provider, time);
  await advanceBlock(provider);
  return Promise.resolve(provider.getBlock("latest"));
}

export function toWei(n: BigNumberish): BigNumber {
  return expandDecimals(n, 18);
}

export function toWeiString(n: BigNumberish): string {
  return expandDecimalsString(n, 18);
}

export function fromWei(n: BigNumberish): string {
  return collapseDecimals(n, 18);
}

export function expandDecimals(n: BigNumberish, decimals = 18): BigNumber {
  return BigNumber.from(new AllBigNumber(n.toString()).multipliedBy(new AllBigNumber(10).pow(decimals)).toFixed(0));
}

export function expandDecimalsString(n: BigNumberish, decimals = 18): string {
  return new AllBigNumber(n.toString()).multipliedBy(new AllBigNumber(10).pow(decimals)).toFixed();
}

export function collapseDecimals(n: BigNumberish, decimals = 18): string {
  return new AllBigNumber(n.toString()).div(new AllBigNumber(10).pow(decimals)).toFixed();
}

export async function getLatestBlockTime(ethers: any): Promise<number> {
  return (await getLatestBlock(ethers)).timestamp;
}

export async function getLatestBlockNumber(ethers: any): Promise<number> {
  return (await getLatestBlock(ethers)).number;
}

export async function getLatestBlock(ethers: any): Promise<{
  hash: string;
  parentHash: string;
  number: number;
  timestamp: number;
  nonce: string;
  difficulty: number;
  gasLimit: BigNumber;
  gasUsed: BigNumber;
  miner: string;
  extraData: string;
}> {
  return await ethers.provider.getBlock("latest");
}

export async function mineBlocks(ethers: any, blocks: number): Promise<any> {
  for (let i = 0; i < blocks; i++) {
    await mineOneBlock(ethers);
    if (i > 0 && i % 1000 == 0) {
      console.log("mine block %d/%d", i + 1, blocks);
    }
  }
}

export async function mineBlockTimeStamp(ethers: any, timestamp: number): Promise<any> {
  return ethers.provider.send("evm_mine", [timestamp]);
}

export async function mineBlock(ethers: any, timestamp: number): Promise<any> {
  return ethers.provider.send("evm_mine", [timestamp]);
}

export async function mineOneBlock(ethers: any): Promise<any> {
  return ethers.provider.send("evm_mine", []);
}