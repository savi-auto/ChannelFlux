;; Title: ChannelFlux - Trustless Bitcoin-Settled State Channels
;; Summary:
;; ChannelFlux introduces a next-generation layer for Bitcoin-backed payment
;; channels, designed to combine the scalability of off-chain settlement with
;; the finality of Bitcoin. Built on Stacks, it ensures secure state anchoring,
;; atomic balance resolution, and seamless cross-chain interoperability.
;;
;; Description:
;; - Off-chain micropayments secured by Bitcoin final settlement
;; - Cooperative and unilateral closing mechanisms with dispute resolution
;; - Balance commitments modeled after Bitcoin's UTXO principles
;; - Lightning-compatible APIs for interoperability and routing
;; - Non-custodial design: participants maintain full control of their assets
;; - Bitcoin-style penalties enforced through time-locked commitments
;;
;; ChannelFlux makes instant, low-cost, and censorship-resistant payments
;; possible while retaining Bitcoin's security guarantees and Stacks' execution
;; capabilities.

;; Contract Constants & Errors
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-CHANNEL-EXISTS (err u101))
(define-constant ERR-CHANNEL-NOT-FOUND (err u102))
(define-constant ERR-INSUFFICIENT-FUNDS (err u103))
(define-constant ERR-INVALID-SIGNATURE (err u104))
(define-constant ERR-CHANNEL-CLOSED (err u105))
(define-constant ERR-DISPUTE-PERIOD (err u106))
(define-constant ERR-INVALID-INPUT (err u107))
(define-constant ERR-BALANCE-MISMATCH (err u108))
(define-constant ERR-UNAUTHORIZED-PARTICIPANT (err u109))

;; Maximum values for safety
(define-constant MAX-BALANCE u1000000000000) ;; 1M STX equivalent
(define-constant MAX-DISPUTE-BLOCKS u1008) ;; ~1 week at 10 min blocks

;; Validation Helpers
(define-private (is-valid-channel-id (channel-id (buff 32)))
  ;; Enforces Bitcoin-compatible 256-bit channel identifiers
  ;; Check length and ensure it's not all zeros
  (and 
    (is-eq (len channel-id) u32)
    (not (is-eq channel-id 0x0000000000000000000000000000000000000000000000000000000000000000))
  )
)

(define-private (is-valid-deposit (amount uint))
  ;; Require minimum deposit (>= 1000 sats equivalent) and maximum safety limit
  (and (>= amount u1000) (<= amount MAX-BALANCE))
)

(define-private (is-valid-balance (balance uint))
  ;; Ensure balance is within reasonable limits
  (<= balance MAX-BALANCE)
)

(define-private (is-valid-signature (signature (buff 65)))
  ;; Bitcoin-compatible ECDSA (secp256k1) signature format
  (is-eq (len signature) u65)
)

(define-private (is-valid-participant (participant principal))
  ;; Ensure participant is not the contract itself or zero address
  (and 
    (not (is-eq participant (as-contract tx-sender)))
    (not (is-eq participant 'ST000000000000000000002AMW42H))) ;; Standard zero address
)

;; Storage: Channel Registry
(define-map payment-channels
  {
    channel-id: (buff 32), ;; Unique channel identifier
    participant-a: principal, ;; Channel initiator
    participant-b: principal, ;; Counterparty
  }
  {
    total-deposited: uint, ;; Funds locked in escrow
    balance-a: uint, ;; Participant A's balance
    balance-b: uint, ;; Participant B's balance
    is-open: bool, ;; Channel state flag
    dispute-deadline: uint, ;; Timeout in block height
    nonce: uint, ;; Sequence counter
  }
)

;; Authorized participants map for additional security
(define-map channel-participants
  {
    channel-id: (buff 32),
    participant: principal,
  }
  {
    authorized: bool,
  }
)

;; Utility Functions
(define-private (uint-to-buff (n uint))
  (unwrap-panic (to-consensus-buff? n))
)

;; Enhanced security check for channel participants
(define-private (is-channel-participant 
    (channel-id (buff 32))
    (participant-a principal)
    (participant-b principal)
    (caller principal)
  )
  (or 
    (is-eq caller participant-a)
    (is-eq caller participant-b)
  )
)

;; Sanitize and validate channel parameters
(define-private (validate-channel-params
    (channel-id (buff 32))
    (participant-b principal)
    (balance-a uint)
    (balance-b uint)
  )
  (and
    (is-valid-channel-id channel-id)
    (is-valid-participant participant-b)
    (is-valid-balance balance-a)
    (is-valid-balance balance-b)
    (not (is-eq tx-sender participant-b))
  )
)

;; Channel Lifecycle

;; Create new channel with enhanced validation
(define-public (create-channel
    (channel-id (buff 32))
    (participant-b principal)
    (initial-deposit uint)
  )
  (begin
    ;; Comprehensive input validation
    (asserts! (is-valid-channel-id channel-id) ERR-INVALID-INPUT)
    (asserts! (is-valid-participant participant-b) ERR-INVALID-INPUT)
    (asserts! (is-valid-deposit initial-deposit) ERR-INVALID-INPUT)
    (asserts! (not (is-eq tx-sender participant-b)) ERR-INVALID-INPUT)

    ;; Ensure channel does not already exist
    (asserts!
      (is-none (map-get? payment-channels {
        channel-id: channel-id,
        participant-a: tx-sender,
        participant-b: participant-b,
      }))
      ERR-CHANNEL-EXISTS
    )

    ;; Lock funds into contract
    (try! (stx-transfer? initial-deposit tx-sender (as-contract tx-sender)))

    ;; Register new channel with validated parameters
    (map-set payment-channels {
      channel-id: channel-id,
      participant-a: tx-sender,
      participant-b: participant-b,
    } {
      total-deposited: initial-deposit,
      balance-a: initial-deposit,
      balance-b: u0,
      is-open: true,
      dispute-deadline: u0,
      nonce: u0,
    })

    ;; Register authorized participants
    (map-set channel-participants {
      channel-id: channel-id,
      participant: tx-sender,
    } { authorized: true })
    
    (map-set channel-participants {
      channel-id: channel-id,
      participant: participant-b,
    } { authorized: true })

    (ok true)
  )
)

;; Fund an existing channel with enhanced security
(define-public (fund-channel
    (channel-id (buff 32))
    (participant-b principal)
    (additional-funds uint)
  )
  (let ((channel (unwrap!
      (map-get? payment-channels {
        channel-id: channel-id,
        participant-a: tx-sender,
        participant-b: participant-b,
      })
      ERR-CHANNEL-NOT-FOUND
    )))