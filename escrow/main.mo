import Principal "mo:base/Principal";
import Result "mo:base/Result";
import Text "mo:base/Text";
import Nat64 "mo:base/Nat64";
import Int "mo:base/Int";
import Buffer "mo:base/Buffer";
import Timer "mo:base/Timer";
import Time "mo:base/Time";
import Error "mo:base/Error"; // CHANGED: needed to catch ledger call failures

actor class EscrowCanister() = Self {

  // ==========================================
  // Types & ICRC Ledger Interfaces
  // ==========================================
  public type Account = {
    owner : Principal;
    subaccount : ?[Nat8];
  };

  public type TransferFromArgs = {
    spender_subaccount : ?[Nat8];
    from : Account;
    to : Account;
    amount : Nat;
    fee : ?Nat;
    memo : ?[Nat8];
    created_at_time : ?Nat64;
  };

  public type TransferArgs = {
    from_subaccount : ?[Nat8];
    to : Account;
    amount : Nat;
    fee : ?Nat;
    memo : ?[Nat8];
    created_at_time : ?Nat64;
  };

  public type AllowanceArgs = {
    account : Account;
    spender : Account;
  };

  public type AllowanceResult = {
    allowance : Nat;
    expires_at : ?Nat64;
  };

  public type TransferError = {
    #BadFee : { expected_fee : Nat };
    #InsufficientFunds : { balance : Nat };
    #InsufficientAllowance : { allowance : Nat };
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #Duplicate : { duplicate_of : Nat };
    #TemporarilyUnavailable;
    #GenericError : { error_code : Nat; message : Text };
  };

  public type TransferResult = {
    #Ok : Nat;
    #Err : TransferError;
  };

  type ICRC1Ledger = actor {
    icrc1_name : () -> async Text;
    icrc2_allowance : (AllowanceArgs) -> async AllowanceResult;
    icrc2_transfer_from : (TransferFromArgs) -> async TransferResult;
    icrc1_transfer : (TransferArgs) -> async TransferResult;
  };

  public type GameOutcome = { #white; #black; #draw };

  public type PlaceBetArgs = {
    player : Principal;
    username : Text;
    anonymous : Bool;
    pot_tier : Nat; // 1, 10, 100, 1000
    amount_e8s : Nat;
    outcome : GameOutcome;
    wallet_address : Text;
  };

  public type StartGameArgs = {
    game_id : Text;
    start_time : Nat;
  };

  public type ReportOutcomeArgs = {
    game_id : Text;
    result : GameOutcome;
    end_time : Nat;
  };

  public type BetRecord = {
    player : Principal;
    username : Text;
    anonymous : Bool;
    pot_tier : Nat;
    amount_e8s : Nat;
    outcome : GameOutcome;
    wallet_address : Text;
  };

  // Caffeine Analytics & History Structures
  public type TierSummary = {
    pot_tier : Nat;
    total_bets : Nat;
    winning_bets : Nat;
    total_pot_e8s : Nat;
  };

  public type GameHistoryRecord = {
    game_id : Text;
    end_time : Nat;
    result : GameOutcome;
    tier_summaries : [TierSummary];
    bets : [BetRecord];
  };

  // CHANGED: new type — records any payout/refund/fee transfer that failed
  public type FailedTransfer = {
    game_id : Text;
    to : Principal;
    amount_e8s : Nat;
    kind : Text; // "fee" | "payout" | "refund"
    error : Text;
    time : Nat;
  };

  public type EscrowError = {
    #Unauthorized;
    #NoApproval;
    #InsufficientAllowance;
    #TransferFailed : Text;
    #InvalidTier;
    #NoActiveGame;
  };

  // ==========================================
  // Configuration & Constants
  // ==========================================
  private let LEDGER_CANISTER_ID = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
  private let DEFAULT_FEE : Nat = 10_000; // Standard ICP transfer fee (0.0001 ICP)

  // CHANGED: platform fee in basis points. 150 bps = 1.5%. (Was: tierTotal / 1000 = 0.1%)
  private let FEE_BPS : Nat = 150;
  private let BPS_DENOMINATOR : Nat = 10_000;

  // 2 Hours Safety Timeout in Nanoseconds
  private let TWO_HOURS_NS : Nat = 2 * 60 * 60 * 1_000_000_000;

  // NNS Fee Recipient Wallet Principal
  private let NNS_FEE_PRINCIPAL = Principal.fromText("hptl6-tqed6-6n3xt-ed7mo-mcsop-yquko-lbhii-je7yn-j4i5t-pjsw4-5ae");

  // Allowlisted JALCA Game Canister
  private var jalcaCanister : Principal = Principal.fromText("py4x3-piaaa-aaaai-ax2ya-cai");

  // Ledger Instance
  private let Ledger : ICRC1Ledger = actor (Principal.toText(LEDGER_CANISTER_ID));

  // ==========================================
  // State Storage
  // ==========================================
  // CHANGED: these two were plain `var` and were WIPED on every upgrade. Now stable.
  // NOTE: on the very first upgrade they start empty, so only upgrade when both are empty.
  private stable var nextGamePots : [BetRecord] = [];
  private stable var lockedGamePots : ?(Text, [BetRecord]) = null; // (game_id, bets)

  // CHANGED: remembers when the locked game started so postupgrade can re-arm the timeout
  private stable var lockedStartNs : Nat = 0;

  private stable var gameHistory : [GameHistoryRecord] = [];

  // CHANGED: log of failed transfers, for reconciliation
  private stable var failedTransfers : [FailedTransfer] = [];

  private var activeGameTimerId : ?Timer.TimerId = null;

  // Helper: Verify JALCA Caller
  private func isJalcaCaller(caller : Principal) : Bool {
    return caller == jalcaCanister;
  };

  // Helper: Outcome Match
  private func isMatchingOutcome(predicted : GameOutcome, actual : GameOutcome) : Bool {
    switch (predicted, actual) {
      case (#white, #white) true;
      case (#black, #black) true;
      case (#draw, #draw) true;
      case (_) false;
    };
  };

  // CHANGED: record a failed transfer instead of silently ignoring it
  private func recordFailure(gameId : Text, to : Principal, amount : Nat, kind : Text, err : Text) {
    let buf = Buffer.fromArray<FailedTransfer>(failedTransfers);
    buf.add({
      game_id = gameId;
      to = to;
      amount_e8s = amount;
      kind = kind;
      error = err;
      time = Int.abs(Time.now());
    });
    failedTransfers := Buffer.toArray(buf);
  };

  // CHANGED: single place that sends ICP out. `amount` is what the recipient receives;
  // the ledger fee (DEFAULT_FEE) is charged on top by the ledger, so callers must
  // subtract it from the gross share BEFORE calling this.
  private func sendTransfer(gameId : Text, to : Principal, amount : Nat, kind : Text) : async Bool {
    try {
      let res = await Ledger.icrc1_transfer({
        from_subaccount = null;
        to = { owner = to; subaccount = null };
        amount = amount;
        fee = ?DEFAULT_FEE;
        memo = null;
        created_at_time = null;
      });
      switch (res) {
        case (#Ok(_)) { return true; };
        case (#Err(e)) {
          recordFailure(gameId, to, amount, kind, debug_show (e));
          return false;
        };
      };
    } catch (e) {
      recordFailure(gameId, to, amount, kind, Error.message(e));
      return false;
    };
  };

  // Internal Safety Timeout Handler
  private func handleGameTimeout(gameId : Text) : async () {
    switch (lockedGamePots) {
      case (null) { }; // Game was already resolved naturally
      case (?(activeId, bets)) {
        if (activeId == gameId) {
          // CHANGED: clear state BEFORE any await so a second call can't settle the same game twice
          lockedGamePots := null;
          lockedStartNs := 0;
          activeGameTimerId := null;

          let tiers : [Nat] = [1, 10, 100, 1000];
          let summariesBuf = Buffer.Buffer<TierSummary>(0);

          for (tier in tiers.vals()) {
            var tierTotal : Nat = 0;
            var tierCount : Nat = 0;
            for (b in bets.vals()) {
              if (b.pot_tier == tier) {
                tierTotal += b.amount_e8s;
                tierCount += 1;
              };
            };
            summariesBuf.add({
              pot_tier = tier;
              total_bets = tierCount;
              winning_bets = 0;
              total_pot_e8s = tierTotal;
            });
          };

          // CHANGED: refund each bettor their OWN stake (previously split the tier pot equally,
          // which is wrong if stakes in a tier differ). No platform fee on timeout refunds.
          for (b in bets.vals()) {
            if (b.amount_e8s > DEFAULT_FEE) {
              ignore await sendTransfer(gameId, b.player, b.amount_e8s - DEFAULT_FEE, "refund");
            } else {
              recordFailure(gameId, b.player, b.amount_e8s, "refund", "amount not above ledger fee");
            };
          };

          // Archive timeout event to history
          let historyRecord : GameHistoryRecord = {
            game_id = gameId;
            end_time = Int.abs(Time.now());
            result = #draw;
            tier_summaries = Buffer.toArray(summariesBuf);
            bets = bets;
          };

          let histBuf = Buffer.fromArray<GameHistoryRecord>(gameHistory);
          histBuf.add(historyRecord);
          gameHistory := Buffer.toArray(histBuf);
        };
      };
    };
  };

  // ==========================================
  // JALCA Interface Endpoints
  // ==========================================

  // 1. Incoming Bet — place_bet
  public shared(msg) func place_bet(args : PlaceBetArgs) : async Result.Result<Nat, EscrowError> {
    if (not isJalcaCaller(msg.caller)) {
      return #err(#Unauthorized);
    };

    if (args.pot_tier != 1 and args.pot_tier != 10 and args.pot_tier != 100 and args.pot_tier != 1000) {
      return #err(#InvalidTier);
    };

    let playerAccount : Account = { owner = args.player; subaccount = null };
    let jelAccount : Account = { owner = Principal.fromActor(Self); subaccount = null };

    let allowanceRes = await Ledger.icrc2_allowance({
      account = playerAccount;
      spender = jelAccount;
    });

    if (allowanceRes.allowance == 0) {
      return #err(#NoApproval);
    };

    if (allowanceRes.allowance < args.amount_e8s + DEFAULT_FEE) {
      return #err(#InsufficientAllowance);
    };

    let transferRes = await Ledger.icrc2_transfer_from({
      spender_subaccount = null;
      from = playerAccount;
      to = jelAccount;
      amount = args.amount_e8s;
      fee = ?DEFAULT_FEE;
      memo = null;
      created_at_time = null;
    });

    switch (transferRes) {
      case (#Ok(blockIndex)) {
        let newBet : BetRecord = {
          player = args.player;
          username = args.username;
          anonymous = args.anonymous;
          pot_tier = args.pot_tier;
          amount_e8s = args.amount_e8s;
          outcome = args.outcome;
          wallet_address = args.wallet_address;
        };

        let buf = Buffer.fromArray<BetRecord>(nextGamePots);
        buf.add(newBet);
        nextGamePots := Buffer.toArray(buf);

        return #ok(blockIndex);
      };
      case (#Err(err)) {
        return #err(#TransferFailed(debug_show(err)));
      };
    };
  };

  // 2. Game Start — start_game
  public shared(msg) func start_game(args : StartGameArgs) : async Result.Result<(), EscrowError> {
    if (not isJalcaCaller(msg.caller)) {
      return #err(#Unauthorized);
    };

    lockedGamePots := ?(args.game_id, nextGamePots);
    lockedStartNs := Int.abs(Time.now()); // CHANGED: remember start time for postupgrade
    nextGamePots := [];

    // Cancel active timer if present
    switch (activeGameTimerId) {
      case (?(tid)) { Timer.cancelTimer(tid); };
      case (null) { };
    };

    // Schedule 2-hour timeout fallback using <system> capability
    let timerId = Timer.setTimer<system>(#nanoseconds(TWO_HOURS_NS), func() : async () {
      await handleGameTimeout(args.game_id);
    });
    activeGameTimerId := ?timerId;

    return #ok(());
  };

  // 3. Game Conclusion — report_outcome
  public shared(msg) func report_outcome(args : ReportOutcomeArgs) : async Result.Result<(), EscrowError> {
    if (not isJalcaCaller(msg.caller)) {
      return #err(#Unauthorized);
    };

    switch (lockedGamePots) {
      case (null) { return #err(#NoActiveGame); };
      case (?(gameId, bets)) {

        // CHANGED: clear locked state and cancel the timer BEFORE any await,
        // so a second report_outcome (or the timeout) can't pay out the same game again.
        lockedGamePots := null;
        lockedStartNs := 0;
        switch (activeGameTimerId) {
          case (?(tid)) { Timer.cancelTimer(tid); activeGameTimerId := null; };
          case (null) { };
        };

        let tiers : [Nat] = [1, 10, 100, 1000];
        let summariesBuf = Buffer.Buffer<TierSummary>(0);

        for (tier in tiers.vals()) {
          var tierTotal : Nat = 0;
          let tierBetsBuf = Buffer.Buffer<BetRecord>(0);
          let winningBetsBuf = Buffer.Buffer<BetRecord>(0);

          for (b in bets.vals()) {
            if (b.pot_tier == tier) {
              tierTotal += b.amount_e8s;
              tierBetsBuf.add(b);

              if (isMatchingOutcome(b.outcome, args.result)) {
                winningBetsBuf.add(b);
              };
            };
          };

          summariesBuf.add({
            pot_tier = tier;
            total_bets = tierBetsBuf.size();
            winning_bets = winningBetsBuf.size();
            total_pot_e8s = tierTotal;
          });

          if (tierTotal > 0) {
            // CHANGED: 1.5% fee (basis points)
            var feeAmount : Nat = tierTotal * FEE_BPS / BPS_DENOMINATOR;

            // CHANGED: if the fee is too small to send after the ledger fee, don't take it
            // (previously it was deducted from the pot but never sent, stranding it).
            if (feeAmount <= DEFAULT_FEE) {
              feeAmount := 0;
            };

            let netPot : Nat = tierTotal - feeAmount;

            if (feeAmount > 0) {
              // CHANGED: ledger fee is paid out of the fee amount, so the pot stays balanced.
              // Your wallet receives feeAmount - DEFAULT_FEE.
              ignore await sendTransfer(gameId, NNS_FEE_PRINCIPAL, feeAmount - DEFAULT_FEE, "fee");
            };

            let recipientsBuf = if (winningBetsBuf.size() > 0) winningBetsBuf else tierBetsBuf;
            let n : Nat = recipientsBuf.size();

            if (n > 0) {
              let share : Nat = netPot / n;
              let remainder : Nat = netPot % n; // CHANGED: leftover e8s go to the first recipient, not stranded
              var idx : Nat = 0;

              for (r in recipientsBuf.vals()) {
                let gross : Nat = if (idx == 0) { share + remainder } else { share };

                if (gross > DEFAULT_FEE) {
                  // CHANGED: ledger fee comes out of the share (was charged on top of it,
                  // draining the canister's pooled balance).
                  ignore await sendTransfer(gameId, r.player, gross - DEFAULT_FEE, "payout");
                } else {
                  recordFailure(gameId, r.player, gross, "payout", "share not above ledger fee");
                };

                idx += 1;
              };
            };
          };
        };

        let historyRecord : GameHistoryRecord = {
          game_id = gameId;
          end_time = args.end_time;
          result = args.result;
          tier_summaries = Buffer.toArray(summariesBuf);
          bets = bets;
        };

        let histBuf = Buffer.fromArray<GameHistoryRecord>(gameHistory);
        histBuf.add(historyRecord);
        gameHistory := Buffer.toArray(histBuf);

        return #ok(());
      };
    };
  };

  // ==========================================
  // Upgrade Hook
  // ==========================================
  // CHANGED: timers do not survive an upgrade. If a game is locked, re-arm its safety
  // timeout for whatever time remains of the original 2 hours.
  system func postupgrade() {
    switch (lockedGamePots) {
      case (null) { };
      case (?(gameId, _)) {
        let nowNs : Nat = Int.abs(Time.now());
        var delay : Nat = TWO_HOURS_NS;

        if (lockedStartNs != 0) {
          let elapsed : Nat = if (nowNs > lockedStartNs) { nowNs - lockedStartNs } else { 0 };
          delay := if (elapsed >= TWO_HOURS_NS) { 1_000_000_000 } else { TWO_HOURS_NS - elapsed };
        };

        let tid = Timer.setTimer<system>(#nanoseconds(delay), func() : async () {
          await handleGameTimeout(gameId);
        });
        activeGameTimerId := ?tid;
      };
    };
  };

  // ==========================================
  // Caffeine Frontend Read-Only Queries
  // ==========================================
  public query func getNextGamePots() : async [BetRecord] {
    return nextGamePots;
  };

  public query func getLockedGamePots() : async ?(Text, [BetRecord]) {
    return lockedGamePots;
  };

  public query func getGameHistory() : async [GameHistoryRecord] {
    return gameHistory;
  };

  // CHANGED: new — lets you (and the frontend) see any transfer that failed
  public query func getFailedTransfers() : async [FailedTransfer] {
    return failedTransfers;
  };

  // CHANGED: new — lets the frontend display the current fee instead of hardcoding it
  public query func getFeeBps() : async Nat {
    return FEE_BPS;
  };

  // ==========================================
  // Diagnostics & System Methods
  // ==========================================
  public shared func testLedgerConnection() : async Text {
    try {
      let name = await Ledger.icrc1_name();
      return "Connected to ledger: " # name;
    } catch (_) {
      return "Ledger connection failed";
    };
  };

  public query func getAllowlist() : async Principal {
    return jalcaCanister;
  };
};