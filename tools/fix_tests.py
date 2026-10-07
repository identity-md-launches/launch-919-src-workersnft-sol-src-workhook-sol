N = r'U:\imd\contracts\test\WorkersNFT.t.sol'
H = r'U:\imd\contracts\test\WorkHook.t.sol'
t = open(N, encoding='utf-8').read()
h = open(H, encoding='utf-8').read()


def rep(txt, old, new):
    assert old in txt, old[:90]
    return txt.replace(old, new, 1)


# cheatcode: prank with a tx.origin
t = rep(t, "    function prank(address) external;\n", "    function prank(address) external;\n    function prank(address, address) external;\n")

# 24h pause + 24h cooldown
t = rep(t, """    function test_PauseExpiresExactlyAt72Hours() public {
        uint256 anchor = _anchor();
        (uint256 nonce,) = _solve(ALICE, anchor, 0, false);
        uint256 resume = vm.getBlockTimestamp() + 72 hours;""", """    function test_PauseExpiresExactlyAt24HoursWithCooldown() public {
        uint256 anchor = _anchor();
        (uint256 nonce,) = _solve(ALICE, anchor, 0, false);
        uint256 resume = vm.getBlockTimestamp() + 24 hours;""")
t = rep(t, """        vm.prank(ALICE);
        nft.mint(anchor, nonce);
        nft.pause();
        vm.expectEmit(false, false, false, true, address(nft));
        emit Unpaused();
        nft.unpause();
        require(!nft.paused());
    }""", """        vm.prank(ALICE);
        nft.mint(anchor, nonce);
        // a new pause needs 24h unpaused after the last one ended
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.pause();
        vm.warp(resume + 24 hours);
        nft.pause();
        vm.expectEmit(false, false, false, true, address(nft));
        emit Unpaused();
        nft.unpause();
        require(!nft.paused());
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.unpause();
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.pause();
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        nft.pause();
        require(nft.paused());
    }""")

# emission is carried forward, never lost
t = rep(t, """    function test_NoRetroactiveRewardsAndPoolExhaustion() public {
        uint256 id = _mint(ALICE);
        nft.endMint();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _activate(ALICE, id);
        eq(nft.pendingWork(id), 0);
        vm.warp(nft.mintEndTime() + 1785 days);
        vm.prank(ALICE);
        eq(nft.claimWork(one(id)), 87_500_000 ether);
        vm.warp(vm.getBlockTimestamp() + 10000 days);
        vm.prank(ALICE);
        eq(nft.claimWork(one(id)), 0);
        eq(nft.miningPool(), 12_500_000 ether);
    }""", """    function test_EmissionWithNoActiveWorkersIsCarriedNotLost() public {
        uint256 id = _mint(ALICE);
        nft.endMint();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        // the first era passed with nobody activated: it is held, not burned
        _activate(ALICE, id);
        eq(nft.emissionCarry(), 12_500_000 ether);
        vm.warp(nft.mintEndTime() + 1785 days);
        vm.prank(ALICE);
        eq(nft.claimWork(one(id)), 100_000_000 ether);
        eq(nft.miningPool(), 0);
        eq(nft.emissionCarry(), 0);
        vm.warp(vm.getBlockTimestamp() + 10000 days);
        vm.prank(ALICE);
        eq(nft.claimWork(one(id)), 0);
    }

    function test_RemainderAfterFinalEraGoesOnlyToBuilders() public {
        _mint(ALICE);
        nft.endMint();
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.releaseMiningRemainder();
        vm.warp(nft.mintEndTime() + 1785 days);
        vm.prank(ALICE);
        vm.expectRevert(WorkOwned.Unauthorized.selector);
        nft.releaseMiningRemainder();
        uint256 before = work.balanceOf(nft.BUILDERS());
        nft.releaseMiningRemainder();
        eq(work.balanceOf(nft.BUILDERS()) - before, 100_000_000 ether);
        eq(nft.miningPool(), 0);
        eq(nft.burnPool(), 50_000_000 ether);
    }""")

t = rep(t, """    function test_PauseStopsAccrualWithoutRetroactiveCatchup() public {""", """    function test_PauseHoldsAccrualAndReleasesItAfterwards() public {""")
a = t.index("    function test_PauseHoldsAccrualAndReleasesItAfterwards() public {")
b = t.index("\n    }\n", a) + len("\n    }\n")
t = t[:a] + """    function test_PauseHoldsAccrualAndReleasesItAfterwards() public {
        uint256 id = _mint(ALICE);
        nft.endMint();
        _activate(ALICE, id);
        uint256 end = nft.mintEndTime();
        vm.warp(end + 1 days);
        nft.pause();
        uint256 earned = nft.pendingWork(id);
        eq(earned, nft.scheduledEmission(end + 1 days));
        vm.warp(end + 1 days + 12 hours);
        // nothing new is paid while paused...
        eq(nft.pendingWork(id), earned);
        vm.prank(ALICE);
        nft.transferFrom(ALICE, BOB, id);
        vm.prank(BOB);
        eq(nft.claimWork(one(id)), earned);
        // ...and the paused share is released once the pause is over, so nothing is lost
        vm.warp(end + 5 days);
        eq(nft.pendingWork(id), nft.scheduledEmission(end + 5 days) - earned);
        vm.prank(BOB);
        nft.claimWork(one(id));
        eq(nft.emissionCarry(), 0);
    }

    function test_BindHookOnlyFromDeployingAccount() public {
        vm.prank(address(0xBEEF), address(0xBAD));
        vm.expectRevert(WorkOwned.Unauthorized.selector);
        nft.bindHook();
    }
""" + t[b:]

# invariant handler: respect cooldown, unpause only when paused
t = rep(t, """        if (pause_ && !nft.paused()) nft.pause();
        else if (!pause_) nft.unpause();""", """        if (pause_ && !nft.paused() && block.timestamp >= nft.pauseCooldownUntil()) nft.pause();
        else if (!pause_ && nft.paused()) nft.unpause();""")
open(N, 'w', encoding='utf-8').write(t)

# hook tests: stand-in knows bindHook (no-op), and an untrusted origin is used where the test means "untrusted sender"
h = rep(h, "contract HookWorkersStandIn {\n", "contract HookWorkersStandIn {\n    function bindHook() external {}\n\n")
h = rep(h, """        workers.bind(address(fresh));
        vm.prank(address(manager));
        vm.expectRevert(WorkHook.InvalidPool.selector);
        fresh.beforeInitialize(ALICE, candidate, 1);""", """        workers.bind(address(fresh));
        vm.prank(address(manager), ALICE);
        vm.expectRevert(WorkHook.InvalidPool.selector);
        fresh.beforeInitialize(ALICE, candidate, 1);""")
open(H, 'w', encoding='utf-8').write(h)
print('tests patched')
