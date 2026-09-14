import Principal "mo:base/Principal";
import Result "mo:base/Result";
import Time "mo:base/Time";
import Array "mo:base/Array";
import HashMap "mo:base/HashMap";
import D "mo:base/Debug";

actor class EscrowCanister() = Self {

  // ==========================================
  // Configuration & Constants
  // ==========================================
  // Mainnet ICP Ledger Principal
  private let LEDGER_CANISTER_ID = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
  private let DEFAULT_FEE : Nat = 10_000; // Standard ICP transfer fee (0.0001 ICP)
  private let TIMEOUT_NANOSEC : Nat64 = 2 * 60 * 60 * 1_000_000_000; // 2 Hours in nanoseconds

  // Allowlisted JALCA Game Canister
  private var jalcaCanister : Principal = Principal.fromText("py4x3-piaaa-aaaai-ax2ya-cai");

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

  // External Ledger Interface
  private let Ledger = actor (Principal.toText(LEDGER_CANISTER_ID)) : service {
    icrc1_name : () -> (Text) query;
    icrc2_allowance : (AllowanceArgs) -> (AllowanceResult) query;
    icrc2_transfer_from : (TransferFromArgs) -> (TransferResult);
    icrc1_transfer : (TransferArgs) -> (TransferResult);
  };

  // Escrow Internal Types
  public type Bet = {
    gameId : Text;
    player : Principal;
    amount : Nat;
    timestamp : Nat64;
    settled : Bool;
  };

  public type EscrowError = {
    #Unauthorized;
    #InsufficientAllowance;
    #TransferFailed : Text;
    #GameNotFound;
    #AlreadySettled;
    #TimeoutNotReached;
  };

  // State Storage
  private var activeBets = HashMap.HashMap<Text, Bet>(10, Text.equal, Text.hash);
  private var pastResults = HashMap.HashMap<Text, Text>(10, Text.equal, Text.hash);

  // ==========================================
  // Authorization Helper
  // ==========================================
  private func isJalcaCaller(caller : Principal) : Bool {
    return caller == jalcaCanister;
  };

  // ==========================================
  // JALCA Update Endpoints
  // ==========================================

  public shared(msg) func test_echo(payload : Text) : async Text {
    if (not isJalcaCaller(msg.caller)) {
      D.trap("Unauthorized caller");
    };
    return "JEL Echo: " # payload;
  };

  public shared(msg) func place_bet(gameId : Text, playerPrincipal : Principal, amount : Nat) : async Result.Result<Nat, EscrowError> {
    if (not isJalcaCaller(msg.caller)) {
      return #err(#Unauthorized);
    };

    let playerAccount : Account = { owner = playerPrincipal; subaccount = null };
    let jelAccount : Account = { owner = Principal.fromActor(Self); subaccount = null };

    let allowanceRes = await Ledger.icrc2_allowance({
      account = playerAccount;
      spender = jelAccount;
    });

    if (allowanceRes.allowance < amount + DEFAULT_FEE) {
      return #err(#InsufficientAllowance);
    };

    let transferRes = await Ledger.icrc2_transfer_from({
      spender_subaccount = null;
      from = playerAccount;
      to = jelAccount;
      amount = amount;
      fee = ?DEFAULT_FEE;
      memo = null;
      created_at_time = null;
    });

    switch (transferRes) {
      case (#Ok(blockIndex)) {
        let newBet : Bet = {
          gameId = gameId;
          player = playerPrincipal;
          amount = amount;
          timestamp = Time.now();
          settled = false;
        };
        activeBets.put(gameId, newBet);
        return #ok(blockIndex);
      };
      case (#Err(_)) {
        return #err(#TransferFailed("ICRC2 Transfer From Failed"));
      };
    };
  };

  public shared(msg) func report_outcome(gameId : Text, winnerPrincipal : Principal) : async Result.Result<Nat, EscrowError> {
    if (not isJalcaCaller(msg.caller)) {
      return #err(#Unauthorized);
    };

    switch (activeBets.get(gameId)) {
      case (null) { return #err(#GameNotFound); };
      case (?bet) {
        if (bet.settled) { return #err(#AlreadySettled); };

        let feeAmount = (bet.amount * 1) / 1000;
        let payoutAmount = bet.amount - feeAmount - DEFAULT_FEE;

        let winnerAccount : Account = { owner = winnerPrincipal; subaccount = null };

        let payoutRes = await Ledger.icrc1_transfer({
          from_subaccount = null;
          to = winnerAccount;
          amount = payoutAmount;
          fee = ?DEFAULT_FEE;
          memo = null;
          created_at_time = null;
        });

        switch (payoutRes) {
          case (#Ok(blockIndex)) {
            let updatedBet = { bet with settled = true };
            activeBets.put(gameId, updatedBet);
            pastResults.put(gameId, "Winner: " # Principal.toText(winnerPrincipal));
            return #ok(blockIndex);
          };
          case (#Err(_)) {
            return #err(#TransferFailed("Payout Transfer Failed"));
          };
        };
      };
    };
  };

  public shared(msg) func refund_timeout(gameId : Text) : async Result.Result<Nat, EscrowError> {
    if (not isJalcaCaller(msg.caller)) {
      return #err(#Unauthorized);
    };

    switch (activeBets.get(gameId)) {
      case (null) { return #err(#GameNotFound); };
      case (?bet) {
        if (bet.settled) { return #err(#AlreadySettled); };

        let now = Time.now();
        if (now - bet.timestamp < TIMEOUT_NANOSEC) {
          return #err(#TimeoutNotReached);
        };

        let playerAccount : Account = { owner = bet.player; subaccount = null };
        let refundAmount = bet.amount - DEFAULT_FEE;

        let refundRes = await Ledger.icrc1_transfer({
          from_subaccount = null;
          to = playerAccount;
          amount = refundAmount;
          fee = ?DEFAULT_FEE;
          memo = null;
          created_at_time = null;
        });

        switch (refundRes) {
          case (#Ok(blockIndex)) {
            let updatedBet = { bet with settled = true };
            activeBets.put(gameId, updatedBet);
            pastResults.put(gameId, "Refunded to Player");
            return #ok(blockIndex);
          };
          case (#Err(_)) {
            return #err(#TransferFailed("Refund Transfer Failed"));
          };
        };
      };
    };
  };

  // ==========================================
  // Public Query Endpoints
  // ==========================================
  public query func testLedgerConnection() : async Text {
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