import Principal "mo:base/Principal";
import Result "mo:base/Result";
import Text "mo:base/Text";
import Nat64 "mo:base/Nat64";
import Buffer "mo:base/Buffer";

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

  // NNS Fee Recipient Wallet Principal
  private let NNS_FEE_PRINCIPAL = Principal.fromText("hptl6-tqed6-6n3xt-ed7mo-mcsop-yquko-lbhii-je7yn-j4i5t-pjsw4-5ae");

  // Allowlisted JALCA Game Canister
  private var jalcaCanister : Principal = Principal.fromText("py4x3-piaaa-aaaai-ax2ya-cai");

  // Ledger Instance
  private let Ledger : ICRC1Ledger = actor (Principal.toText(LEDGER_CANISTER_ID));

  // ==========================================
  // Double-Buffered Pot Storage
  // ==========================================
  private var nextGamePots : [BetRecord] = [];
  private var lockedGamePots : ?(Text, [BetRecord]) = null; // (game_id, bets)

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

  // ==========================================
  // JALCA Interface Endpoints
  // ==========================================

  // 1. Incoming Bet — place_bet
  public shared(msg) func place_bet(args : PlaceBetArgs) : async Result.Result<Nat, EscrowError> {
    if (not isJalcaCaller(msg.caller)) {
      return #err(#Unauthorized);
    };

    // Verify valid tier
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

    // Lock current next-game pots and open a fresh set
    lockedGamePots := ?(args.game_id, nextGamePots);
    nextGamePots := [];

    return #ok(());
  };

  // 3. Game Conclusion — report_outcome
  public shared(msg) func report_outcome(args : ReportOutcomeArgs) : async Result.Result<(), EscrowError> {
    if (not isJalcaCaller(msg.caller)) {
      return #err(#Unauthorized);
    };

    switch (lockedGamePots) {
      case (null) { return #err(#NoActiveGame); };
      case (?(_, bets)) {
        
        let tiers : [Nat] = [1, 10, 100, 1000];

        // Process each tier independently
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

          if (tierTotal > 0) {
            // Deduct 0.1% Owner Fee (1 / 1000)
            let feeAmount = tierTotal / 1000;
            let netPot = tierTotal - feeAmount;

            // Safe Fee Transfer (Transfers full feeAmount; ledger deducts DEFAULT_FEE from canister)
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

            // Distribute remaining pot
            let recipientsBuf = if (winningBetsBuf.size() > 0) winningBetsBuf else tierBetsBuf;
            if (recipientsBuf.size() > 0) {
              let sharePerRecipient = netPot / recipientsBuf.size();

              // Safe Payout Transfer (Transfers full share; ledger deducts DEFAULT_FEE from canister)
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

        // Clear locked pots
        lockedGamePots := null;
        return #ok(());
      };
    };
  };

  // ==========================================
  // Public Inter-Canister & Query Endpoints
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