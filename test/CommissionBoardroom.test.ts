import chai, {expect} from "chai";
import {ethers} from "hardhat";
import {solidity} from "ethereum-waffle";
import {Contract, ContractFactory, BigNumber, utils} from "ethers";
import {SignerWithAddress} from 'hardhat-deploy-ethers/dist/src/signer-with-address';
import { Provider } from '@ethersproject/providers';

import {
    ADDRESS_ZERO, fromWei,
    getLatestBlock,
    getLatestBlockNumber,
    maxUint256,
    mineBlocks, mineBlockTimeStamp,
    toWei
} from "./shared/utilities";

chai.use(solidity);

async function latestBlocktime(provider: Provider): Promise<number> {
    const {timestamp} = await provider.getBlock("latest");
    return timestamp;
}

describe("CommissionBoardroom.test", () => {
    const DAY = 86400;
    const ETH = utils.parseEther("1");
    const ZERO = BigNumber.from(0);
    const STAKE_AMOUNT = ETH.mul(5000);
    const SUBTRACTED_FEE_STAKED_AMOUNT = ETH.mul(4800);
    const SEIGNIORAGE_AMOUNT = ETH.mul(10000);
    const EARNED_SEIGNIORAGE_AMOUNT = utils.parseEther("9999.9999999999999984");

    const {provider} = ethers;

    let operator: SignerWithAddress;
    let whale: SignerWithAddress;
    let abuser: SignerWithAddress;
    let rewardPool: SignerWithAddress;
    let daoFund: SignerWithAddress;

    before("provider & accounts setting", async () => {
        [operator, whale, abuser, rewardPool, daoFund] = await ethers.getSigners();
    });

    let Dollar: ContractFactory;
    let Bond: ContractFactory;
    let Share: ContractFactory;
    let MockERC20: ContractFactory;
    let Treasury: ContractFactory;
    let CommissionBoardroom: ContractFactory;

    before("fetch contract factories", async () => {
        Dollar = await ethers.getContractFactory("Dollar");
        Bond = await ethers.getContractFactory("Bond");
        Share = await ethers.getContractFactory("Share");
        MockERC20 = await ethers.getContractFactory("MockERC20");
        Treasury = await ethers.getContractFactory("Treasury");
        CommissionBoardroom = await ethers.getContractFactory("CommissionBoardroom");
    });

    let dollar: Contract;
    let bond: Contract;
    let share: Contract;
    let rewardToken: Contract;
    let treasury: Contract;
    let boardroom: Contract;

    let startTime: BigNumber;

    beforeEach("deploy contracts", async () => {
        dollar = await Dollar.connect(operator).deploy();
        bond = await Bond.connect(operator).deploy();
        share = await Share.connect(operator).deploy();
        rewardToken = await MockERC20.connect(operator).deploy("VLP MDG/MDO", "LP", 18);
        treasury = await Treasury.connect(operator).deploy();
        startTime = BigNumber.from(await latestBlocktime(provider)).add(DAY);
        treasury = await Treasury.connect(operator).deploy();
        await dollar.connect(operator).mint(treasury.address, utils.parseEther("10000"));
        await treasury.connect(operator).initialize(dollar.address, bond.address, share.address, startTime);
        // boardroom = await CommissionBoardroom.connect(operator).deploy(dollar.address, share.address, treasury.address);
        boardroom = await CommissionBoardroom.connect(operator).deploy();
        await boardroom.connect(operator).initialize(dollar.address, share.address, ADDRESS_ZERO, daoFund.address);
        // await boardroom.connect(operator).setLockUp(0, 0);
    });

    describe("#stake", () => {
        it("should work correctly", async () => {
            await Promise.all([
                share.connect(operator).distributeReward(rewardPool.address),
                share.connect(rewardPool).transfer(whale.address, STAKE_AMOUNT),
                share.connect(whale).approve(boardroom.address, STAKE_AMOUNT),
            ]);

            await expect(boardroom.connect(whale).stake(STAKE_AMOUNT)).to.emit(boardroom, "Staked").withArgs(whale.address, SUBTRACTED_FEE_STAKED_AMOUNT);

            const latestSnapshotIndex = await boardroom.latestSnapshotIndex();

            expect(await boardroom.balanceOf(whale.address)).to.eq(SUBTRACTED_FEE_STAKED_AMOUNT);

            expect(await share.balanceOf(daoFund.address)).to.eq(ETH.mul(200));

            expect(await boardroom.getLastSnapshotIndexOf(whale.address)).to.eq(latestSnapshotIndex);
        });

        it("should fail when user tries to stake with zero amount", async () => {
            await expect(boardroom.connect(whale).stake(ZERO)).to.revertedWith("CommissionBoardroom: Cannot stake 0");
        });

        it("should fail initialize twice", async () => {
            await expect(boardroom.initialize(dollar.address, share.address, treasury.address, daoFund.address)).to.revertedWith("CommissionBoardroom: already initialized");
        });
    });

    describe("#withdraw", () => {
        beforeEach("stake", async () => {
            await Promise.all([
                share.connect(operator).distributeReward(rewardPool.address),
                share.connect(rewardPool).transfer(whale.address, STAKE_AMOUNT),
                share.connect(whale).approve(boardroom.address, STAKE_AMOUNT),
            ]);
            await boardroom.connect(whale).stake(STAKE_AMOUNT);
        });

        it("should work correctly", async () => {
            await expect(boardroom.connect(whale).withdraw(SUBTRACTED_FEE_STAKED_AMOUNT)).to.emit(boardroom, "Withdrawn").withArgs(whale.address, SUBTRACTED_FEE_STAKED_AMOUNT);

            expect(await share.balanceOf(whale.address)).to.eq(SUBTRACTED_FEE_STAKED_AMOUNT);
            expect(await boardroom.balanceOf(whale.address)).to.eq(ZERO);
        });
    });

    describe("#exit", async () => {
        beforeEach("stake", async () => {
            await Promise.all([
                share.connect(operator).distributeReward(rewardPool.address),
                share.connect(rewardPool).transfer(whale.address, STAKE_AMOUNT),
                share.connect(whale).approve(boardroom.address, STAKE_AMOUNT),
            ]);
            await boardroom.connect(whale).stake(STAKE_AMOUNT);
        });

        it("should work correctly", async () => {
            await expect(boardroom.connect(whale).exit()).to.emit(boardroom, "Withdrawn").withArgs(whale.address, SUBTRACTED_FEE_STAKED_AMOUNT);

            expect(await share.balanceOf(whale.address)).to.eq(SUBTRACTED_FEE_STAKED_AMOUNT);
            expect(await boardroom.balanceOf(whale.address)).to.eq(ZERO);
        });
    });

    describe("#allocateSeigniorage", () => {
        beforeEach("stake", async () => {
            await Promise.all([
                share.connect(operator).distributeReward(rewardPool.address),
                share.connect(rewardPool).transfer(whale.address, STAKE_AMOUNT),
                share.connect(whale).approve(boardroom.address, STAKE_AMOUNT),
            ]);
            await boardroom.connect(whale).stake(STAKE_AMOUNT);
        });

        it("should allocate seigniorage to stakers", async () => {
            await dollar.connect(operator).mint(operator.address, SEIGNIORAGE_AMOUNT);
            await dollar.connect(operator).approve(boardroom.address, SEIGNIORAGE_AMOUNT);

            await expect(boardroom.connect(operator).allocateSeigniorage(SEIGNIORAGE_AMOUNT))
                .to.emit(boardroom, "RewardAdded")
                .withArgs(operator.address, SEIGNIORAGE_AMOUNT);

            expect(await boardroom.earned(whale.address)).to.eq(EARNED_SEIGNIORAGE_AMOUNT);
        });
    });

    describe("#claimDividends", () => {
        beforeEach("stake", async () => {
            await Promise.all([
                share.connect(operator).distributeReward(rewardPool.address),
                share.connect(rewardPool).transfer(whale.address, STAKE_AMOUNT),
                share.connect(whale).approve(boardroom.address, STAKE_AMOUNT),

                share.connect(rewardPool).transfer(abuser.address, STAKE_AMOUNT),
                share.connect(abuser).approve(boardroom.address, STAKE_AMOUNT),
            ]);
            await boardroom.connect(whale).stake(STAKE_AMOUNT);
        });

        it("should claim dividends", async () => {
            await dollar.connect(operator).mint(operator.address, SEIGNIORAGE_AMOUNT);
            await dollar.connect(operator).approve(boardroom.address, SEIGNIORAGE_AMOUNT);
            await boardroom.connect(operator).allocateSeigniorage(SEIGNIORAGE_AMOUNT);

            await expect(boardroom.connect(whale).claimReward()).to.emit(boardroom, "RewardPaid").withArgs(whale.address, EARNED_SEIGNIORAGE_AMOUNT);
            expect(await boardroom.balanceOf(whale.address)).to.eq(SUBTRACTED_FEE_STAKED_AMOUNT);
        });
    });

    describe("#addRewardPool and #claimPoolRewards", () => {
        beforeEach("addRewardPool and stake", async () => {
            await Promise.all([
                share.connect(operator).distributeReward(rewardPool.address),
                share.connect(rewardPool).transfer(whale.address, STAKE_AMOUNT),
                share.connect(whale).approve(boardroom.address, STAKE_AMOUNT),

                share.connect(rewardPool).transfer(abuser.address, STAKE_AMOUNT),
                share.connect(abuser).approve(boardroom.address, STAKE_AMOUNT),

                rewardToken.connect(operator).mint(boardroom.address, STAKE_AMOUNT),
            ]);
            await boardroom.connect(operator).addRewardPool(rewardToken.address, 100, 200, utils.parseEther('0.01'));
            await boardroom.connect(whale).stake(STAKE_AMOUNT);
            console.log('[whale.stake] latestBlockNumber = %s', String(await getLatestBlockNumber(ethers)));
        });

        it("should claim dividends and reward", async () => {
            await dollar.connect(operator).mint(operator.address, SEIGNIORAGE_AMOUNT);
            await dollar.connect(operator).approve(boardroom.address, SEIGNIORAGE_AMOUNT);
            await boardroom.connect(operator).allocateSeigniorage(SEIGNIORAGE_AMOUNT);

            console.log('[allocateSeigniorage] latestBlockNumber = %s', String(await getLatestBlockNumber(ethers)));
            console.log('boardroom.pendingReward(0, whale.address) = %s', String(await boardroom.pendingReward(0, whale.address)));

            await expect(boardroom.connect(whale).claimReward()).to.emit(boardroom, "RewardPaid").withArgs(whale.address, EARNED_SEIGNIORAGE_AMOUNT);
            expect(await boardroom.balanceOf(whale.address)).to.eq(SUBTRACTED_FEE_STAKED_AMOUNT);

            expect(await dollar.balanceOf(whale.address)).to.eq(EARNED_SEIGNIORAGE_AMOUNT);
            expect(await rewardToken.balanceOf(whale.address)).to.eq(utils.parseEther('0.0399999999999984'));

            console.log('[whale.claimReward] latestBlockNumber = %s', String(await getLatestBlockNumber(ethers)));
        });
    });
});
