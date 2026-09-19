import Principal "mo:base/Principal";
import Result "mo:base/Result";
import Text "mo:base/Text";
import Nat64 "mo:base/Nat64";
import Int "mo:base/Int";
import Buffer "mo:base/Buffer";
import Timer "mo:base/Timer";
import Time "mo:base/Time";

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
  private var nextGamePots : [BetRecord] = [];
  private var lockedGamePots : ?(Text, [BetRecord]) = null; // (game_id, bets)
  private stable var gameHistory : [GameHistoryRecord] = [];
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

  // Internal Safety Timeout Handler
  private func handleGameTimeout(gameId : Text) : async () {
    switch (lockedGamePots) {
      case (null) { }; // Game was already resolved naturally
      case (?(activeId, bets)) {
        if (activeId == gameId) {
          let tiers : [Nat] = [1, 10, 100, 1000];
          let summariesBuf = Buffer.Buffer<TierSummary>(0);

          for (tier in tiers.vals()) {
            var tierTotal : Nat = 0;
            let tierBetsBuf = Buffer.Buffer<BetRecord>(0);

            for (b in bets.vals()) {
              if (b.pot_tier == tier) {
                tierTotal += b.amount_e8s;
                tierBetsBuf.add(b);
              };
            };

            summariesBuf.add({
              pot_tier = tier;
              total_bets = tierBetsBuf.size();
              winning_bets = 0;
              total_pot_e8s = tierTotal;
            });

            // Return 100% of pot equally to all bettors in this tier
            if (tierTotal > 0 and tierBetsBuf.size() > 0) {
              let sharePerRecipient = tierTotal / tierBetsBuf.size();
              if (sharePerRecipient > DEFAULT_FEE) {
                for (r in tierBetsBuf.vals()) {
                  ignore await Ledger.icrc1_transfer({
                    from_subaccount = null;
                    to = { owner = r.player; subaccount = null };
                    amount = sharePerRecipient - DEFAULT_FEE;
                    fee = ?DEFAULT_FEE;
                    memo = null;
                    created_at_time = null;
                  });
                };
              };
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

          // Reset active state
          lockedGamePots := null;
          activeGameTimerId := null;
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
      case (#Err(_)) {
        return #err(#TransferFailed("ICRC2 Pull Failed"));
      };
    };
  };

  // 2. Game Start — start_game
  public shared(msg) func start_game(args : StartGameArgs) : async Result.Result<(), EscrowError> {
    if (not isJalcaCaller(msg.caller)) {
      return #err(#Unauthorized);
    };

    lockedGamePots := ?(args.game_id, nextGamePots);
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

    // Cancel safety timer since game completed within time limit
    switch (activeGameTimerId) {
      case (?(tid)) { Timer.cancelTimer(tid); activeGameTimerId := null; };
      case (null) { };
    };

    switch (lockedGamePots) {
      case (null) { return #err(#NoActiveGame); };
      case (?(gameId, bets)) {
        
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
            let feeAmount = tierTotal / 1000;
            let netPot = tierTotal - feeAmount;

            if (feeAmount > DEFAULT_FEE) {
              ignore await Ledger.icrc1_transfer({
                from_subaccount = null;
                to = { owner = NNS_FEE_PRINCIPAL; subaccount = null };
                amount = feeAmount;
                fee = ?DEFAULT_FEE;
                memo = null;
                created_at_time = null;
              });
            };

            let recipientsBuf = if (winningBetsBuf.size() > 0) winningBetsBuf else tierBetsBuf;
            if (recipientsBuf.size() > 0) {
              let sharePerRecipient = netPot / recipientsBuf.size();

              if (sharePerRecipient > DEFAULT_FEE) {
                for (r in recipientsBuf.vals()) {
                  ignore await Ledger.icrc1_transfer({
                    from_subaccount = null;
                    to = { owner = r.player; subaccount = null };
                    amount = sharePerRecipient;
                    fee = ?DEFAULT_FEE;
                    memo = null;
                    created_at_time = null;
                  });
                };
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

        lockedGamePots := null;
        return #ok(());
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