;; Weather Trigger Payout Engine
;; Parametric insurance contract for automated weather-based payouts

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-already-exists (err u102))
(define-constant err-invalid-params (err u103))
(define-constant err-insufficient-funds (err u104))
(define-constant err-policy-expired (err u105))
(define-constant err-policy-not-active (err u106))
(define-constant err-already-claimed (err u107))
(define-constant err-unauthorized (err u108))
(define-constant err-trigger-not-met (err u109))
(define-constant err-invalid-oracle (err u110))

;; Data Variables
(define-data-var policy-nonce uint u0)
(define-data-var oracle-nonce uint u0)
(define-data-var total-premiums-collected uint u0)
(define-data-var total-payouts-disbursed uint u0)

;; Data Maps
(define-map policies
  uint
  {
    farmer: principal,
    premium: uint,
    coverage-amount: uint,
    rainfall-threshold: uint,
    temperature-threshold: uint,
    start-timestamp: uint,
    end-timestamp: uint,
    is-active: bool,
    is-claimed: bool,
    payout-amount: uint
  }
)

(define-map weather-data
  { policy-id: uint, timestamp: uint }
  {
    rainfall: uint,
    temperature: uint,
    oracle-address: principal,
    verified: bool
  }
)

(define-map authorized-oracles
  principal
  {
    is-authorized: bool,
    data-points-submitted: uint,
    reputation-score: uint
  }
)

(define-map farmer-policies
  principal
  (list 50 uint)
)

(define-map policy-claims
  uint
  {
    claim-timestamp: uint,
    trigger-met: bool,
    total-rainfall: uint,
    average-temperature: uint,
    payout-executed: bool
  }
)

;; Read-only functions
(define-read-only (get-policy-details (policy-id uint))
  (map-get? policies policy-id)
)

(define-read-only (get-weather-data (policy-id uint) (timestamp uint))
  (map-get? weather-data { policy-id: policy-id, timestamp: timestamp })
)

(define-read-only (get-oracle-info (oracle principal))
  (map-get? authorized-oracles oracle)
)

(define-read-only (get-farmer-policies (farmer principal))
  (default-to (list) (map-get? farmer-policies farmer))
)

(define-read-only (get-claim-details (policy-id uint))
  (map-get? policy-claims policy-id)
)

(define-read-only (get-contract-stats)
  (ok {
    total-policies: (var-get policy-nonce),
    total-premiums: (var-get total-premiums-collected),
    total-payouts: (var-get total-payouts-disbursed),
    contract-balance: (stx-get-balance (as-contract tx-sender))
  })
)

(define-read-only (check-trigger-conditions (policy-id uint) (rainfall uint) (temperature uint))
  (match (map-get? policies policy-id)
    policy
    (ok {
      rainfall-trigger-met: (<= rainfall (get rainfall-threshold policy)),
      temperature-trigger-met: (>= temperature (get temperature-threshold policy)),
      any-trigger-met: (or 
        (<= rainfall (get rainfall-threshold policy))
        (>= temperature (get temperature-threshold policy))
      )
    })
    err-not-found
  )
)

;; Public functions
(define-public (create-policy 
    (premium uint)
    (coverage-amount uint)
    (rainfall-threshold uint)
    (temperature-threshold uint)
    (start-timestamp uint)
    (end-timestamp uint)
  )
  (let
    (
      (policy-id (+ (var-get policy-nonce) u1))
      (farmer tx-sender)
    )
    (asserts! (> coverage-amount u0) err-invalid-params)
    (asserts! (> premium u0) err-invalid-params)
    (asserts! (> end-timestamp start-timestamp) err-invalid-params)
    (asserts! (>= coverage-amount premium) err-invalid-params)
    
    ;; Transfer premium from farmer to contract
    (try! (stx-transfer? premium farmer (as-contract tx-sender)))
    
    ;; Create policy
    (map-set policies policy-id
      {
        farmer: farmer,
        premium: premium,
        coverage-amount: coverage-amount,
        rainfall-threshold: rainfall-threshold,
        temperature-threshold: temperature-threshold,
        start-timestamp: start-timestamp,
        end-timestamp: end-timestamp,
        is-active: true,
        is-claimed: false,
        payout-amount: u0
      }
    )
    
    ;; Update farmer's policy list
    (map-set farmer-policies farmer
      (unwrap! (as-max-len? (append (get-farmer-policies farmer) policy-id) u50) err-invalid-params)
    )
    
    ;; Update stats
    (var-set policy-nonce policy-id)
    (var-set total-premiums-collected (+ (var-get total-premiums-collected) premium))
    
    (ok policy-id)
  )
)

(define-public (authorize-oracle (oracle principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (map-set authorized-oracles oracle
      {
        is-authorized: true,
        data-points-submitted: u0,
        reputation-score: u100
      }
    )
    (ok true)
  )
)

(define-public (revoke-oracle (oracle principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (match (map-get? authorized-oracles oracle)
      oracle-info
      (begin
        (map-set authorized-oracles oracle
          (merge oracle-info { is-authorized: false })
        )
        (ok true)
      )
      err-not-found
    )
  )
)

(define-public (submit-weather-data
    (policy-id uint)
    (timestamp uint)
    (rainfall uint)
    (temperature uint)
  )
  (let
    (
      (oracle tx-sender)
      (oracle-info (unwrap! (map-get? authorized-oracles oracle) err-unauthorized))
    )
    (asserts! (get is-authorized oracle-info) err-unauthorized)
    (asserts! (is-some (map-get? policies policy-id)) err-not-found)
    
    ;; Store weather data
    (map-set weather-data
      { policy-id: policy-id, timestamp: timestamp }
      {
        rainfall: rainfall,
        temperature: temperature,
        oracle-address: oracle,
        verified: true
      }
    )
    
    ;; Update oracle stats
    (map-set authorized-oracles oracle
      (merge oracle-info 
        { data-points-submitted: (+ (get data-points-submitted oracle-info) u1) }
      )
    )
    
    (ok true)
  )
)

(define-public (evaluate-claim (policy-id uint) (total-rainfall uint) (average-temperature uint))
  (let
    (
      (policy (unwrap! (map-get? policies policy-id) err-not-found))
    )
    (asserts! (get is-active policy) err-policy-not-active)
    (asserts! (not (get is-claimed policy)) err-already-claimed)
    (asserts! (is-eq tx-sender (get farmer policy)) err-unauthorized)
    
    ;; Check if trigger conditions are met
    (let
      (
        (rainfall-trigger (<= total-rainfall (get rainfall-threshold policy)))
        (temperature-trigger (>= average-temperature (get temperature-threshold policy)))
        (trigger-met (or rainfall-trigger temperature-trigger))
      )
      (asserts! trigger-met err-trigger-not-met)
      
      ;; Record claim
      (map-set policy-claims policy-id
        {
          claim-timestamp: block-height,
          trigger-met: true,
          total-rainfall: total-rainfall,
          average-temperature: average-temperature,
          payout-executed: false
        }
      )
      
      (ok trigger-met)
    )
  )
)

(define-public (execute-payout (policy-id uint))
  (let
    (
      (policy (unwrap! (map-get? policies policy-id) err-not-found))
      (claim (unwrap! (map-get? policy-claims policy-id) err-not-found))
    )
    (asserts! (get is-active policy) err-policy-not-active)
    (asserts! (not (get is-claimed policy)) err-already-claimed)
    (asserts! (get trigger-met claim) err-trigger-not-met)
    (asserts! (not (get payout-executed claim)) err-already-claimed)
    (asserts! (is-eq tx-sender (get farmer policy)) err-unauthorized)
    
    ;; Execute payout
    (try! (as-contract (stx-transfer? (get coverage-amount policy) tx-sender (get farmer policy))))
    
    ;; Update policy status
    (map-set policies policy-id
      (merge policy 
        { 
          is-claimed: true,
          payout-amount: (get coverage-amount policy)
        }
      )
    )
    
    ;; Update claim status
    (map-set policy-claims policy-id
      (merge claim { payout-executed: true })
    )
    
    ;; Update stats
    (var-set total-payouts-disbursed 
      (+ (var-get total-payouts-disbursed) (get coverage-amount policy))
    )
    
    (ok (get coverage-amount policy))
  )
)

(define-public (cancel-policy (policy-id uint))
  (let
    (
      (policy (unwrap! (map-get? policies policy-id) err-not-found))
    )
    (asserts! (is-eq tx-sender (get farmer policy)) err-unauthorized)
    (asserts! (get is-active policy) err-policy-not-active)
    (asserts! (not (get is-claimed policy)) err-already-claimed)
    
    ;; Deactivate policy
    (map-set policies policy-id
      (merge policy { is-active: false })
    )
    
    (ok true)
  )
)

(define-public (update-oracle-reputation (oracle principal) (new-score uint))
  (let
    (
      (oracle-info (unwrap! (map-get? authorized-oracles oracle) err-not-found))
    )
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (<= new-score u100) err-invalid-params)
    
    (map-set authorized-oracles oracle
      (merge oracle-info { reputation-score: new-score })
    )
    
    (ok true)
  )
)

(define-public (withdraw-surplus (amount uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (>= (stx-get-balance (as-contract tx-sender)) amount) err-insufficient-funds)
    
    (try! (as-contract (stx-transfer? amount tx-sender contract-owner)))
    (ok true)
  )
)


;; title: weather-trigger-payout-engine
;; version:
;; summary:
;; description:

;; traits
;;

;; token definitions
;;

;; constants
;;

;; data vars
;;

;; data maps
;;

;; public functions
;;

;; read only functions
;;

;; private functions
;;

