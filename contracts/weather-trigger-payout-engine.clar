;; Weather Trigger Payout Engine - Parametric Insurance
;; Monitors weather/satellite data, triggers parametric payouts, manages policy terms, prevents fraud, and settles claims

(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-unauthorized (err u102))
(define-constant err-invalid-amount (err u103))
(define-constant err-already-claimed (err u104))
(define-constant err-inactive-policy (err u105))
(define-constant err-season-ended (err u106))

(define-data-var policy-nonce uint u0)
(define-data-var trigger-nonce uint u0)
(define-data-var claim-nonce uint u0)

;; Insurance Policies
(define-map policies
  { policy-id: uint }
  {
    farmer: principal,
    crop-type: (string-ascii 50),
    coverage-amount: uint,
    premium-paid: uint,
    location: (string-ascii 100),
    trigger-threshold: int,
    season-start: uint,
    season-end: uint,
    active: bool,
    claims-count: uint,
    created-at: uint
  }
)

;; Weather Data from Oracles
(define-map weather-data
  { location: (string-ascii 100), date: uint }
  {
    rainfall: int,
    temperature: int,
    humidity: uint,
    recorded-by: principal,
    verified: bool,
    timestamp: uint
  }
)

;; Parametric Triggers
(define-map triggers
  { trigger-id: uint }
  {
    policy-id: uint,
    trigger-type: (string-ascii 50),
    threshold-value: int,
    actual-value: int,
    triggered-at: uint,
    payout-amount: uint,
    verified: bool
  }
)

;; Payouts
(define-map payouts
  { policy-id: uint, trigger-id: uint }
  {
    amount: uint,
    paid: bool,
    payment-date: uint,
    status: (string-ascii 20),
    recipient: principal
  }
)

;; Oracle Registry
(define-map oracle-registry
  { oracle: principal }
  {
    verified: bool,
    data-points-submitted: uint,
    accuracy-score: uint,
    active: bool,
    registered-at: uint
  }
)

;; Claims History
(define-map claims
  { claim-id: uint }
  {
    policy-id: uint,
    trigger-id: uint,
    farmer: principal,
    claim-amount: uint,
    status: (string-ascii 20),
    filed-at: uint,
    processed-at: uint
  }
)

;; Policy Statistics
(define-map policy-stats
  { farmer: principal }
  {
    total-policies: uint,
    active-policies: uint,
    total-claims: uint,
    total-payouts: uint
  }
)

;; Read-Only Functions

(define-read-only (get-policy (policy-id uint))
  (map-get? policies { policy-id: policy-id })
)

(define-read-only (get-weather-data (location (string-ascii 100)) (date uint))
  (map-get? weather-data { location: location, date: date })
)

(define-read-only (get-trigger (trigger-id uint))
  (map-get? triggers { trigger-id: trigger-id })
)

(define-read-only (get-payout (policy-id uint) (trigger-id uint))
  (map-get? payouts { policy-id: policy-id, trigger-id: trigger-id })
)

(define-read-only (get-oracle (oracle principal))
  (map-get? oracle-registry { oracle: oracle })
)

(define-read-only (get-claim (claim-id uint))
  (map-get? claims { claim-id: claim-id })
)

(define-read-only (get-farmer-stats (farmer principal))
  (map-get? policy-stats { farmer: farmer })
)

;; Public Functions

;; Register Oracle
(define-public (register-oracle)
  (begin
    (asserts! (is-none (get-oracle tx-sender)) err-already-claimed)
    (map-set oracle-registry
      { oracle: tx-sender }
      {
        verified: false,
        data-points-submitted: u0,
        accuracy-score: u0,
        active: true,
        registered-at: block-height
      }
    )
    (ok true)
  )
)

;; Verify Oracle
(define-public (verify-oracle (oracle principal))
  (let
    ((oracle-data (unwrap! (get-oracle oracle) err-not-found)))
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (map-set oracle-registry
      { oracle: oracle }
      (merge oracle-data { verified: true })
    )
    (ok true)
  )
)

;; Create Insurance Policy
(define-public (create-policy
  (crop-type (string-ascii 50))
  (coverage-amount uint)
  (premium uint)
  (location (string-ascii 100))
  (trigger-threshold int)
  (season-start uint)
  (season-end uint))
  (let
    ((new-id (+ (var-get policy-nonce) u1))
     (farmer-stats (default-to
       { total-policies: u0, active-policies: u0, total-claims: u0, total-payouts: u0 }
       (get-farmer-stats tx-sender))))
    (asserts! (> coverage-amount u0) err-invalid-amount)
    (asserts! (> premium u0) err-invalid-amount)
    (asserts! (< season-start season-end) err-invalid-amount)
    
    (map-set policies
      { policy-id: new-id }
      {
        farmer: tx-sender,
        crop-type: crop-type,
        coverage-amount: coverage-amount,
        premium-paid: premium,
        location: location,
        trigger-threshold: trigger-threshold,
        season-start: season-start,
        season-end: season-end,
        active: true,
        claims-count: u0,
        created-at: block-height
      }
    )
    
    (map-set policy-stats
      { farmer: tx-sender }
      {
        total-policies: (+ (get total-policies farmer-stats) u1),
        active-policies: (+ (get active-policies farmer-stats) u1),
        total-claims: (get total-claims farmer-stats),
        total-payouts: (get total-payouts farmer-stats)
      }
    )
    
    (var-set policy-nonce new-id)
    (ok new-id)
  )
)

;; Submit Weather Data
(define-public (submit-weather-data
  (location (string-ascii 100))
  (date uint)
  (rainfall int)
  (temperature int)
  (humidity uint))
  (let
    ((oracle-data (unwrap! (get-oracle tx-sender) err-not-found)))
    (asserts! (get verified oracle-data) err-unauthorized)
    (asserts! (get active oracle-data) err-unauthorized)
    
    (map-set weather-data
      { location: location, date: date }
      {
        rainfall: rainfall,
        temperature: temperature,
        humidity: humidity,
        recorded-by: tx-sender,
        verified: true,
        timestamp: block-height
      }
    )
    
    (map-set oracle-registry
      { oracle: tx-sender }
      (merge oracle-data {
        data-points-submitted: (+ (get data-points-submitted oracle-data) u1)
      })
    )
    (ok true)
  )
)

;; Check Trigger Conditions
(define-public (check-trigger (policy-id uint) (date uint))
  (let
    ((policy (unwrap! (get-policy policy-id) err-not-found))
     (weather (unwrap! (get-weather-data (get location policy) date) err-not-found))
     (new-trigger-id (+ (var-get trigger-nonce) u1)))
    (asserts! (get active policy) err-inactive-policy)
    (asserts! (>= block-height (get season-start policy)) err-unauthorized)
    (asserts! (<= block-height (get season-end policy)) err-season-ended)
    
    (if (< (get rainfall weather) (get trigger-threshold policy))
      (begin
        (map-set triggers
          { trigger-id: new-trigger-id }
          {
            policy-id: policy-id,
            trigger-type: "drought",
            threshold-value: (get trigger-threshold policy),
            actual-value: (get rainfall weather),
            triggered-at: block-height,
            payout-amount: (get coverage-amount policy),
            verified: true
          }
        )
        (map-set payouts
          { policy-id: policy-id, trigger-id: new-trigger-id }
          {
            amount: (get coverage-amount policy),
            paid: false,
            payment-date: u0,
            status: "pending",
            recipient: (get farmer policy)
          }
        )
        (var-set trigger-nonce new-trigger-id)
        (ok new-trigger-id)
      )
      (ok u0)
    )
  )
)

;; File Claim
(define-public (file-claim (policy-id uint) (trigger-id uint))
  (let
    ((new-claim-id (+ (var-get claim-nonce) u1))
     (policy (unwrap! (get-policy policy-id) err-not-found))
     (trigger (unwrap! (get-trigger trigger-id) err-not-found))
     (payout (unwrap! (get-payout policy-id trigger-id) err-not-found)))
    (asserts! (is-eq tx-sender (get farmer policy)) err-unauthorized)
    (asserts! (get verified trigger) err-unauthorized)
    (asserts! (is-eq (get status payout) "pending") err-already-claimed)
    
    (map-set claims
      { claim-id: new-claim-id }
      {
        policy-id: policy-id,
        trigger-id: trigger-id,
        farmer: tx-sender,
        claim-amount: (get amount payout),
        status: "filed",
        filed-at: block-height,
        processed-at: u0
      }
    )
    
    (var-set claim-nonce new-claim-id)
    (ok new-claim-id)
  )
)

;; Execute Payout
(define-public (execute-payout (policy-id uint) (trigger-id uint))
  (let
    ((payout (unwrap! (get-payout policy-id trigger-id) err-not-found))
     (trigger (unwrap! (get-trigger trigger-id) err-not-found))
     (policy (unwrap! (get-policy policy-id) err-not-found))
     (farmer-stats (unwrap! (get-farmer-stats (get farmer policy)) err-not-found)))
    (asserts! (is-eq (get status payout) "pending") err-already-claimed)
    (asserts! (not (get paid payout)) err-already-claimed)
    
    (map-set payouts
      { policy-id: policy-id, trigger-id: trigger-id }
      (merge payout {
        paid: true,
        payment-date: block-height,
        status: "completed"
      })
    )
    
    (map-set policies
      { policy-id: policy-id }
      (merge policy {
        claims-count: (+ (get claims-count policy) u1)
      })
    )
    
    (map-set policy-stats
      { farmer: (get farmer policy) }
      (merge farmer-stats {
        total-claims: (+ (get total-claims farmer-stats) u1),
        total-payouts: (+ (get total-payouts farmer-stats) (get amount payout))
      })
    )
    
    (ok true)
  )
)

;; Cancel Policy
(define-public (cancel-policy (policy-id uint))
  (let
    ((policy (unwrap! (get-policy policy-id) err-not-found))
     (farmer-stats (unwrap! (get-farmer-stats (get farmer policy)) err-not-found)))
    (asserts! (is-eq tx-sender (get farmer policy)) err-unauthorized)
    (asserts! (get active policy) err-inactive-policy)
    
    (map-set policies
      { policy-id: policy-id }
      (merge policy { active: false })
    )
    
    (map-set policy-stats
      { farmer: (get farmer policy) }
      (merge farmer-stats {
        active-policies: (- (get active-policies farmer-stats) u1)
      })
    )
    (ok true)
  )
)

;; Update Oracle Score
(define-public (update-oracle-score (oracle principal) (score uint))
  (let
    ((oracle-data (unwrap! (get-oracle oracle) err-not-found)))
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (<= score u100) err-invalid-amount)
    
    (map-set oracle-registry
      { oracle: oracle }
      (merge oracle-data { accuracy-score: score })
    )
    (ok true)
  )
)
