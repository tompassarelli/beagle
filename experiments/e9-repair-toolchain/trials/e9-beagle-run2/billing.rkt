#lang beagle

(ns billing)
(define-mode strict)

(require catalog :as cat)
(require customers :as cust)
(require orders :as ord)

;; --- scalars ---------------------------------------------------------------

(defscalar InvoiceId Long)
(defscalar PaymentId Long)

;; =============================================================================
;; Records
;; =============================================================================

(defrecord Invoice [(id : InvoiceId) (order-id : ord/OrderId) (customer-id : cust/CustomerId)
                    (subtotal : ord/Amount) (tax : ord/Amount) (discount : ord/Amount)
                    (total : ord/Amount) (status : String) (issued-at : ord/Timestamp)
                    (due-at : ord/Timestamp) (paid-at : ord/Timestamp)])

(defrecord Payment [(id : PaymentId) (invoice-id : InvoiceId) (amount : ord/Amount)
                    (method : String) (status : String)
                    (processed-at : ord/Timestamp)])

(defrecord CreditNote [(id : Long) (customer-id : cust/CustomerId) (amount : ord/Amount)
                       (reason : String) (issued-at : ord/Timestamp)])

;; =============================================================================
;; Invoice operations
;; =============================================================================

(defn create-invoice [(id : InvoiceId) (order : Any) (customer : Any)
                      (issued-at : ord/Timestamp) (due-at : ord/Timestamp)] : Invoice
  (let [sub   (ord/order-subtotal order)
        tx    (ord/order-tax order)
        disc  (ord/order-discount order)
        tot   (ord/order-total order)
        cid   (cust/customer-id customer)
        oid   (ord/order-id order)]
    (->Invoice id oid cid sub tx disc tot "unpaid" issued-at due-at (->Timestamp 0))))

(defn find-invoice-by-id [(invoices : Any) (id : InvoiceId)] : Any
  (first (filterv (fn [inv] (= (invoiceid-value (invoice-id inv)) (invoiceid-value id))) invoices)))

(defn invoices-for-customer [(invoices : Any) (customer-id : cust/CustomerId)] : Any
  (filterv (fn [inv] (= (customerid-value (invoice-customer-id inv)) (customerid-value customer-id))) invoices))

(defn invoices-for-order [(invoices : Any) (order-id : ord/OrderId)] : Any
  (filterv (fn [inv] (= (orderid-value (invoice-order-id inv)) (orderid-value order-id))) invoices))

(defn invoices-by-status [(invoices : Any) (status : String)] : Any
  (filterv (fn [inv] (= (invoice-status inv) status)) invoices))

(defn unpaid-invoices [(invoices : Any)] : Any
  (invoices-by-status invoices "unpaid"))

(defn paid-invoices [(invoices : Any)] : Any
  (invoices-by-status invoices "paid"))

(defn overdue-invoices [(invoices : Any) (now : ord/Timestamp)] : Any
  (filterv (fn [inv] (and (= (invoice-status inv) "unpaid")
                          (< (timestamp-value (invoice-due-at inv)) (timestamp-value now))))
           invoices))

(defn mark-invoice-paid [(inv : Invoice) (paid-at : ord/Timestamp)] : Invoice
  (->Invoice (invoice-id inv) (invoice-order-id inv) (invoice-customer-id inv)
             (invoice-subtotal inv) (invoice-tax inv) (invoice-discount inv)
             (invoice-total inv) "paid" (invoice-issued-at inv)
             (invoice-status inv) paid-at))

(defn invoice-age-days [(inv : Invoice) (now : ord/Timestamp)] : Long
  (quot (- (timestamp-value now) (timestamp-value (invoice-issued-at inv))) 86400))

;; =============================================================================
;; Payment operations
;; =============================================================================

(defn create-payment [(id : PaymentId) (invoice-id : InvoiceId) (amount : ord/Amount)
                      (method : String) (processed-at : ord/Timestamp)] : Payment
  (->Payment id invoice-id amount method "completed" processed-at))

(defn find-payment-by-id [(payments : Any) (id : PaymentId)] : Any
  (first (filterv (fn [p] (= (paymentid-value (payment-id p)) (paymentid-value id))) payments)))

(defn payments-for-invoice [(payments : Any) (invoice-id : InvoiceId)] : Any
  (filterv (fn [p] (= (invoiceid-value (payment-invoice-id p)) (invoiceid-value invoice-id))) payments))

(defn total-payments-for-invoice [(payments : Any) (invoice-id : InvoiceId)] : Long
  (reduce (fn [acc p] (+ acc (amount-value (payment-amount p))))
          0
          (filterv (fn [p] (and (= (invoiceid-value (payment-invoice-id p)) (invoiceid-value invoice-id))
                                (= (payment-status p) "completed")))
                   payments)))

(defn invoice-balance [(inv : Invoice) (payments : Any)] : Long
  (let [paid (total-payments-for-invoice payments (invoice-id inv))
        owed (amount-value (invoice-total inv))
        bal  (- owed paid)]
    (if (<= bal 0) 0 bal)))

(defn invoice-fully-paid? [(inv : Invoice) (payments : Any)] : Boolean
  (= (invoice-balance inv payments) 0))

(defn payments-by-method [(payments : Any) (method : String)] : Any
  (filterv (fn [p] (= (payment-method p) method)) payments))

(defn refund-payment [(p : Payment)] : Payment
  (->Payment (payment-id p) (payment-invoice-id p) (payment-amount p)
             (payment-method p) "refunded" (payment-processed-at p)))

;; =============================================================================
;; Credit note operations
;; =============================================================================

(defn create-credit-note [(id : Long) (customer-id : cust/CustomerId) (amount : ord/Amount)
                          (reason : String) (issued-at : ord/Timestamp)] : CreditNote
  (->CreditNote id customer-id amount reason issued-at))

(defn credits-for-customer [(credits : Any) (customer-id : cust/CustomerId)] : Any
  (filterv (fn [cn] (= (customerid-value (creditnote-customer-id cn)) (customerid-value customer-id))) credits))

(defn total-credits-for-customer [(credits : Any) (customer-id : cust/CustomerId)] : Long
  (reduce (fn [acc cn] (+ acc (amount-value (creditnote-amount cn))))
          0
          (credits-for-customer credits customer-id)))

;; =============================================================================
;; Aggregations
;; =============================================================================

(defn total-revenue-collected [(payments : Any)] : Long
  (reduce (fn [acc p] (+ acc (amount-value (payment-amount p))))
          0
          (filterv (fn [p] (= (payment-status p) "completed")) payments)))

(defn total-outstanding [(invoices : Any) (payments : Any)] : Long
  (reduce (fn [acc inv] (+ acc (invoice-balance inv payments)))
          0
          (unpaid-invoices invoices)))

(defn customer-total-billed [(invoices : Any) (customer-id : cust/CustomerId)] : Long
  (reduce (fn [acc inv] (+ acc (amount-value (invoice-total inv))))
          0
          (invoices-for-customer invoices customer-id)))

(defn customer-total-paid [(payments : Any) (invoices : Any)
                           (customer-id : cust/CustomerId)] : Long
  (let [cust-invoices (invoices-for-customer invoices customer-id)
        cust-inv-ids  (mapv invoice-id cust-invoices)]
    (reduce (fn [acc p]
              (if (and (= (payment-status p) "completed")
                       (some (fn [iid] (= (invoiceid-value (payment-invoice-id p)) (invoiceid-value iid)))
                             cust-inv-ids))
                  (+ acc (amount-value (payment-amount p)))
                  acc))
            0 payments)))

(defn revenue-by-method [(payments : Any)] : Any
  (let [completed (filterv (fn [p] (= (payment-status p) "completed")) payments)]
    (reduce (fn [acc p]
              (let [m   (payment-method p)
                    cur (get acc m)
                    old (if (nil? cur) 0 cur)]
                (assoc acc m (+ old (amount-value (payment-amount p))))))
            {} completed)))

(defn avg-days-to-pay [(invoices : Any)] : Long
  (let [pd (paid-invoices invoices)
        cnt (count pd)]
    (if (= cnt 0) 0
        (quot (reduce (fn [acc inv]
                        (+ acc (quot (- (timestamp-value (invoice-paid-at inv))
                                        (timestamp-value (invoice-issued-at inv)))
                                     86400)))
                      0 pd)
              cnt))))

(defn collection-rate-pct [(invoices : Any) (payments : Any)] : Long
  (let [total-invoiced (reduce (fn [acc inv] (+ acc (amount-value (invoice-total inv))))
                               0 invoices)
        collected      (total-revenue-collected payments)]
    (if (= total-invoiced 0) 100
        (quot (* collected 100) total-invoiced))))

;; =============================================================================
;; Invoice formatting helpers
;; =============================================================================

(defn invoice-summary [(inv : Invoice)] : String
  (str "Invoice #" (invoiceid-value (invoice-id inv))
       " | Order #" (orderid-value (invoice-order-id inv))
       " | " (invoice-status inv)
       " | Total: " (cat/format-price (->Price (amount-value (invoice-total inv))))))

(defn invoice-detail [(inv : Invoice)] : String
  (str "Invoice #" (invoiceid-value (invoice-id inv))
       " | Customer: " (customerid-value (invoice-customer-id inv))
       " | Sub: " (cat/format-price (->Price (amount-value (invoice-subtotal inv))))
       " | Tax: " (cat/format-price (->Price (amount-value (invoice-tax inv))))
       " | Disc: " (cat/format-price (->Price (amount-value (invoice-discount inv))))
       " | Total: " (cat/format-price (->Price (amount-value (invoice-total inv))))
       " | Status: " (invoice-status inv)))

(defn payment-summary [(p : Payment)] : String
  (str "Payment #" (paymentid-value (payment-id p))
       " | Invoice #" (invoiceid-value (payment-invoice-id p))
       " | " (cat/format-price (->Price (amount-value (payment-amount p))))
       " | " (payment-method p)
       " | " (payment-status p)))

(defn credit-note-summary [(cn : CreditNote)] : String
  (str "Credit #" (creditnote-id cn)
       " | Customer: " (customerid-value (creditnote-customer-id cn))
       " | " (cat/format-price (->Price (amount-value (creditnote-amount cn))))
       " | " (creditnote-reason cn)))

;; =============================================================================
;; Invoice validation
;; =============================================================================

(defn valid-invoice? [(inv : Invoice)] : Boolean
  (and (> (invoiceid-value (invoice-id inv)) 0)
       (> (orderid-value (invoice-order-id inv)) 0)
       (> (customerid-value (invoice-customer-id inv)) 0)
       (>= (amount-value (invoice-total inv)) 0)
       (not= (invoice-status inv) "")))

(defn valid-payment? [(p : Payment)] : Boolean
  (and (> (paymentid-value (payment-id p)) 0)
       (> (invoiceid-value (payment-invoice-id p)) 0)
       (> (amount-value (payment-amount p)) 0)
       (not= (payment-method p) "")))

(defn valid-credit-note? [(cn : CreditNote)] : Boolean
  (and (> (creditnote-id cn) 0)
       (> (customerid-value (creditnote-customer-id cn)) 0)
       (> (amount-value (creditnote-amount cn)) 0)
       (not= (creditnote-reason cn) "")))

;; =============================================================================
;; Invoice sorting
;; =============================================================================

(defn sort-invoices-by-total [(invoices : Any)] : Any
  (sort-by (fn [inv] (amount-value (invoice-total inv))) invoices))

(defn sort-invoices-by-date [(invoices : Any)] : Any
  (sort-by (fn [inv] (timestamp-value (invoice-issued-at inv))) invoices))

(defn sort-invoices-by-due [(invoices : Any)] : Any
  (sort-by (fn [inv] (timestamp-value (invoice-due-at inv))) invoices))

(defn sort-payments-by-date [(payments : Any)] : Any
  (sort-by (fn [p] (timestamp-value (payment-processed-at p))) payments))

;; =============================================================================
;; Additional invoice queries
;; =============================================================================

(defn invoices-in-period [(invoices : Any) (start-ts : ord/Timestamp)
                          (end-ts : ord/Timestamp)] : Any
  (filterv (fn [inv] (and (>= (timestamp-value (invoice-issued-at inv)) (timestamp-value start-ts))
                          (<= (timestamp-value (invoice-issued-at inv)) (timestamp-value end-ts))))
           invoices))

(defn payments-in-period [(payments : Any) (start-ts : ord/Timestamp)
                          (end-ts : ord/Timestamp)] : Any
  (filterv (fn [p] (and (>= (timestamp-value (payment-processed-at p)) (timestamp-value start-ts))
                        (<= (timestamp-value (payment-processed-at p)) (timestamp-value end-ts))))
           payments))

(defn invoices-for-amount-range [(invoices : Any) (lo : ord/Amount)
                                 (hi : ord/Amount)] : Any
  (filterv (fn [inv] (and (>= (amount-value (invoice-total inv)) (amount-value lo))
                          (<= (amount-value (invoice-total inv)) (amount-value hi))))
           invoices))

;; =============================================================================
;; Customer billing analytics
;; =============================================================================

(defn customer-invoice-count [(invoices : Any) (customer-id : cust/CustomerId)] : Long
  (count (invoices-for-customer invoices customer-id)))

(defn customer-unpaid-count [(invoices : Any) (customer-id : cust/CustomerId)] : Long
  (count (filterv (fn [inv] (and (= (customerid-value (invoice-customer-id inv)) (customerid-value customer-id))
                                 (= (invoice-status inv) "unpaid")))
                  invoices)))

(defn customer-outstanding-balance [(invoices : Any) (payments : Any)
                                    (customer-id : cust/CustomerId)] : Long
  (let [cust-unpaid (filterv (fn [inv]
                               (and (= (customerid-value (invoice-customer-id inv)) (customerid-value customer-id))
                                    (= (invoice-status inv) "unpaid")))
                             invoices)]
    (reduce (fn [acc inv] (+ acc (invoice-balance inv payments)))
            0 cust-unpaid)))

(defn customer-avg-invoice-value [(invoices : Any)
                                  (customer-id : cust/CustomerId)] : Long
  (let [cust-invs (invoices-for-customer invoices customer-id)
        cnt (count cust-invs)]
    (if (= cnt 0) 0
        (quot (reduce (fn [acc inv] (+ acc (amount-value (invoice-total inv))))
                      0 cust-invs)
              cnt))))

;; =============================================================================
;; Payment analytics
;; =============================================================================

(defn payment-count-by-method [(payments : Any) (method : String)] : Long
  (count (filterv (fn [p] (and (= (payment-method p) method)
                               (= (payment-status p) "completed")))
                  payments)))

(defn total-refunded [(payments : Any)] : Long
  (reduce (fn [acc p] (+ acc (amount-value (payment-amount p))))
          0
          (filterv (fn [p] (= (payment-status p) "refunded")) payments)))

(defn net-revenue [(payments : Any)] : Long
  (- (total-revenue-collected payments) (total-refunded payments)))

(defn completed-payment-count [(payments : Any)] : Long
  (count (filterv (fn [p] (= (payment-status p) "completed")) payments)))

(defn avg-payment-amount [(payments : Any)] : Long
  (let [completed (filterv (fn [p] (= (payment-status p) "completed")) payments)
        cnt (count completed)]
    (if (= cnt 0) 0
        (quot (reduce (fn [acc p] (+ acc (amount-value (payment-amount p)))) 0 completed)
              cnt))))

;; =============================================================================
;; Credit note analytics
;; =============================================================================

(defn total-credits-issued [(credits : Any)] : Long
  (reduce (fn [acc cn] (+ acc (amount-value (creditnote-amount cn)))) 0 credits))

(defn credit-note-count [(credits : Any)] : Long
  (count credits))

(defn customer-credit-count [(credits : Any) (customer-id : cust/CustomerId)] : Long
  (count (credits-for-customer credits customer-id)))

(defn avg-credit-note-amount [(credits : Any)] : Long
  (let [cnt (count credits)]
    (if (= cnt 0) 0
        (quot (total-credits-issued credits) cnt))))

;; =============================================================================
;; Cross-module integration helpers
;; =============================================================================

(defn invoice-matches-order? [(inv : Invoice) (orders : Any)] : Boolean
  (let [o (ord/find-order-by-id orders (invoice-order-id inv))]
    (if (nil? o) false
        (= (amount-value (invoice-total inv)) (amount-value (ord/order-total o))))))

(defn invoice-order-status [(inv : Invoice) (orders : Any)] : String
  (let [o (ord/find-order-by-id orders (invoice-order-id inv))]
    (if (nil? o) "unknown" (ord/order-status o))))

(defn customer-billing-summary [(invoices : Any) (payments : Any)
                                (credits : Any)
                                (customer-id : cust/CustomerId)] : String
  (let [billed      (customer-total-billed invoices customer-id)
        paid        (customer-total-paid payments invoices customer-id)
        outstanding (customer-outstanding-balance invoices payments customer-id)
        credit-amt  (total-credits-for-customer credits customer-id)]
    (str "Customer #" (customerid-value customer-id)
         " | Billed: " (cat/format-price (->Price billed))
         " | Paid: " (cat/format-price (->Price paid))
         " | Outstanding: " (cat/format-price (->Price outstanding))
         " | Credits: " (cat/format-price (->Price credit-amt)))))

;; =============================================================================
;; Aging buckets
;; =============================================================================

(defn invoice-age-bucket [(inv : Invoice) (now : ord/Timestamp)] : String
  (let [days (invoice-age-days inv now)]
    (cond
      [(< days 30) "current"]
      [(< days 60) "30-60"]
      [(< days 90) "60-90"]
      [true "90+"])))

(defn aging-report [(invoices : Any) (now : ord/Timestamp)] : Any
  (let [unpaid (unpaid-invoices invoices)
        current-cnt (count (filterv (fn [inv] (= (invoice-age-bucket inv now) "current")) unpaid))
        d30-cnt     (count (filterv (fn [inv] (= (invoice-age-bucket inv now) "30-60")) unpaid))
        d60-cnt     (count (filterv (fn [inv] (= (invoice-age-bucket inv now) "60-90")) unpaid))
        d90-cnt     (count (filterv (fn [inv] (= (invoice-age-bucket inv now) "90+")) unpaid))]
    {:current current-cnt :30-60 d30-cnt :60-90 d60-cnt :90+ d90-cnt}))

(defn aging-total [(invoices : Any) (payments : Any) (now : ord/Timestamp)] : Any
  (let [unpaid (unpaid-invoices invoices)
        bucket-total (fn [bucket-name]
                       (reduce (fn [acc inv]
                                 (if (= (invoice-age-bucket inv now) bucket-name)
                                     (+ acc (invoice-balance inv payments))
                                     acc))
                               0 unpaid))]
    {:current (bucket-total "current")
     :30-60   (bucket-total "30-60")
     :60-90   (bucket-total "60-90")
     :90+     (bucket-total "90+")}))

;; =============================================================================
;; Batch / bulk operations
;; =============================================================================

(defn bulk-create-invoices [(specs : Any)] : Any
  (mapv (fn [spec]
          (let [id        (nth spec 0)
                order     (nth spec 1)
                customer  (nth spec 2)
                issued    (nth spec 3)
                due       (nth spec 4)]
            (create-invoice id order customer issued due)))
        specs))

(defn overdue-invoice-ids [(invoices : Any) (now : ord/Timestamp)] : Any
  (mapv invoice-id (overdue-invoices invoices now)))

;; =============================================================================
;; Top-N queries
;; =============================================================================

(defn largest-invoices [(invoices : Any) (n : Long)] : Any
  (vec (take n (reverse (sort-invoices-by-total invoices)))))

(defn largest-payments [(payments : Any) (n : Long)] : Any
  (vec (take n (reverse (sort-by (fn [p] (amount-value (payment-amount p))) payments)))))

(defn most-indebted-customer-ids [(invoices : Any) (payments : Any)] : Any
  (let [unpaid (unpaid-invoices invoices)
        cids   (distinct (mapv invoice-customer-id unpaid))]
    (reverse (sort-by (fn [cid]
                        (customer-outstanding-balance invoices payments cid))
                      cids))))

;; =============================================================================
;; Reconciliation helpers
;; =============================================================================

(defn sum-invoice-totals-in-period [(invoices : Any) (start-ts : ord/Timestamp)
                                    (end-ts : ord/Timestamp)] : Long
  (reduce (fn [acc inv] (+ acc (amount-value (invoice-total inv))))
          0
          (invoices-in-period invoices start-ts end-ts)))

(defn sum-payments-in-period [(payments : Any) (start-ts : ord/Timestamp)
                              (end-ts : ord/Timestamp)] : Long
  (reduce (fn [acc p] (+ acc (amount-value (payment-amount p))))
          0
          (filterv (fn [p] (= (payment-status p) "completed"))
                   (payments-in-period payments start-ts end-ts))))

(defn invoice-payment-gap [(invoices : Any) (payments : Any)
                           (start-ts : ord/Timestamp) (end-ts : ord/Timestamp)] : Long
  (- (sum-invoice-totals-in-period invoices start-ts end-ts)
     (sum-payments-in-period payments start-ts end-ts)))

;; =============================================================================
;; Dunning / collection helpers
;; =============================================================================

(defn days-past-due [(inv : Invoice) (now : ord/Timestamp)] : Long
  (let [diff (- (timestamp-value (invoice-due-at inv)) (timestamp-value now))]
    (if (<= diff 0) 0 (quot diff 86400))))

(defn severely-overdue [(invoices : Any) (now : ord/Timestamp)
                        (threshold-days : Long)] : Any
  (filterv (fn [inv] (and (= (invoice-status inv) "unpaid")
                          (> (days-past-due inv now) threshold-days)))
           invoices))

(defn overdue-total [(invoices : Any) (now : ord/Timestamp)] : Long
  (reduce (fn [acc inv] (+ acc (amount-value (invoice-total inv))))
          0
          (overdue-invoices invoices now)))

(defn avg-days-past-due [(invoices : Any) (now : ord/Timestamp)] : Long
  (let [unpaid (unpaid-invoices invoices)
        cnt    (count unpaid)]
    (if (= cnt 0) 0
        (quot (reduce (fn [acc inv] (+ acc (days-past-due inv now)))
                      0 unpaid)
              cnt))))

;; =============================================================================
;; Payment application / waterfall
;; =============================================================================

(defn apply-payment-to-invoice [(inv : Invoice) (payments : Any)
                                 (pay-id : PaymentId) (amount : ord/Amount)
                                 (method : String)
                                 (processed-at : ord/Timestamp)] : Any
  (let [bal         (invoice-balance inv payments)
        applied     (if (> (amount-value amount) bal) bal (amount-value amount))
        remaining   (- (amount-value amount) applied)
        new-payment (create-payment pay-id (invoice-id inv) (->Amount applied)
                                    method processed-at)
        new-bal     (- bal applied)
        new-inv     (if (= new-bal 0)
                        (mark-invoice-paid inv processed-at)
                        inv)]
    {:invoice new-inv :payment new-payment :remaining remaining}))

(defn split-payment-across-invoices [(invoices : Any) (payments : Any)
                                      (start-pay-id : PaymentId)
                                      (total-amount : ord/Amount)
                                      (method : String)
                                      (processed-at : ord/Timestamp)] : Any
  (let [sorted-unpaid (sort-invoices-by-date (unpaid-invoices invoices))]
    (first
      (reduce (fn [state inv]
                (let [created   (first state)
                      remaining (second state)
                      next-id   (nth state 2)]
                  (if (<= remaining 0)
                      state
                      (let [bal      (invoice-balance inv payments)
                            applied  (if (> remaining bal) bal remaining)
                            pay      (create-payment (->PaymentId next-id) (invoice-id inv)
                                                     (->Amount applied) method processed-at)
                            left     (- remaining applied)]
                        [(conj created pay) left (+ next-id 1)]))))
              [[] (amount-value total-amount) (paymentid-value start-pay-id)]
              sorted-unpaid))))

;; =============================================================================
;; Invoice lifecycle tracking
;; =============================================================================

(defn invoice-lifecycle-status [(inv : Invoice) (payments : Any)
                                 (now : ord/Timestamp)] : String
  (cond
    [(= (invoice-status inv) "paid") "paid"]
    [(invoice-fully-paid? inv payments) "paid-pending-mark"]
    [(> (days-past-due inv now) 90) "severely-overdue"]
    [(> (days-past-due inv now) 0) "overdue"]
    [true "current"]))

(defn invoice-health-score [(inv : Invoice) (payments : Any)
                             (now : ord/Timestamp)] : Long
  (let [status (invoice-lifecycle-status inv payments now)]
    (cond
      [(= status "paid") 100]
      [(= status "paid-pending-mark") 95]
      [(= status "current") 80]
      [(= status "overdue")
       (let [dpd (days-past-due inv now)]
         (if (> dpd 90) 0
             (- 60 (quot (* dpd 60) 90))))]
      [true 0])))

(defn portfolio-health [(invoices : Any) (payments : Any) (now : ord/Timestamp)] : Long
  (let [cnt (count invoices)]
    (if (= cnt 0) 100
        (quot (reduce (fn [acc inv]
                        (+ acc (invoice-health-score inv payments now)))
                      0 invoices)
              cnt))))

;; =============================================================================
;; Revenue recognition helpers
;; =============================================================================

(defn recognized-revenue [(invoices : Any)] : Long
  (reduce (fn [acc inv] (+ acc (amount-value (invoice-total inv))))
          0
          (paid-invoices invoices)))

(defn unrecognized-revenue [(invoices : Any)] : Long
  (reduce (fn [acc inv] (+ acc (amount-value (invoice-total inv))))
          0
          (unpaid-invoices invoices)))

(defn deferred-revenue-pct [(invoices : Any)] : Long
  (let [total (reduce (fn [acc inv] (+ acc (amount-value (invoice-total inv)))) 0 invoices)]
    (if (= total 0) 0
        (quot (* (unrecognized-revenue invoices) 100) total))))

;; =============================================================================
;; Customer credit & balance sheet
;; =============================================================================

(defn customer-net-position [(invoices : Any) (payments : Any)
                              (credits : Any) (customer-id : cust/CustomerId)] : Long
  (let [billed  (customer-total-billed invoices customer-id)
        paid    (customer-total-paid payments invoices customer-id)
        cred    (total-credits-for-customer credits customer-id)]
    (- billed (+ paid cred))))

(defn customer-has-credit? [(credits : Any) (customer-id : cust/CustomerId)] : Boolean
  (> (total-credits-for-customer credits customer-id) 0))

(defn customer-lifetime-value [(payments : Any) (invoices : Any)
                                (customer-id : cust/CustomerId)] : Long
  (customer-total-paid payments invoices customer-id))

(defn customer-payment-velocity [(invoices : Any)
                                  (customer-id : cust/CustomerId)] : Long
  (let [cust-paid (filterv (fn [inv]
                             (and (= (customerid-value (invoice-customer-id inv)) (customerid-value customer-id))
                                  (= (invoice-status inv) "paid")))
                           invoices)
        cnt (count cust-paid)]
    (if (= cnt 0) 0
        (quot (reduce (fn [acc inv]
                        (+ acc (quot (- (timestamp-value (invoice-paid-at inv))
                                        (timestamp-value (invoice-issued-at inv)))
                                     86400)))
                      0 cust-paid)
              cnt))))

;; =============================================================================
;; Discount and tax analysis
;; =============================================================================

(defn total-tax-billed [(invoices : Any)] : Long
  (reduce (fn [acc inv] (+ acc (amount-value (invoice-tax inv)))) 0 invoices))

(defn total-discounts-billed [(invoices : Any)] : Long
  (reduce (fn [acc inv] (+ acc (amount-value (invoice-discount inv)))) 0 invoices))

(defn effective-tax-rate [(invoices : Any)] : Long
  (let [total-sub (reduce (fn [acc inv] (+ acc (amount-value (invoice-subtotal inv))))
                          0 invoices)]
    (if (= total-sub 0) 0
        (quot (* (total-tax-billed invoices) 100) total-sub))))

(defn effective-discount-rate [(invoices : Any)] : Long
  (let [total-sub (reduce (fn [acc inv] (+ acc (amount-value (invoice-subtotal inv))))
                          0 invoices)]
    (if (= total-sub 0) 0
        (quot (* (total-discounts-billed invoices) 100) total-sub))))

;; =============================================================================
;; Period comparison analytics
;; =============================================================================

(defn revenue-collected-in-period [(payments : Any) (start-ts : ord/Timestamp)
                                    (end-ts : ord/Timestamp)] : Long
  (reduce (fn [acc p] (+ acc (amount-value (payment-amount p))))
          0
          (filterv (fn [p] (and (= (payment-status p) "completed")
                                (>= (timestamp-value (payment-processed-at p)) (timestamp-value start-ts))
                                (<= (timestamp-value (payment-processed-at p)) (timestamp-value end-ts))))
                   payments)))

(defn invoiced-in-period [(invoices : Any) (start-ts : ord/Timestamp)
                           (end-ts : ord/Timestamp)] : Long
  (sum-invoice-totals-in-period invoices start-ts end-ts))

(defn period-collection-rate [(invoices : Any) (payments : Any)
                               (start-ts : ord/Timestamp) (end-ts : ord/Timestamp)] : Long
  (let [issued    (invoiced-in-period invoices start-ts end-ts)
        collected (revenue-collected-in-period payments start-ts end-ts)]
    (if (= issued 0) 100
        (quot (* collected 100) issued))))

;; =============================================================================
;; Invoice-to-order cross-checks
;; =============================================================================

(defn orders-without-invoices [(orders : Any) (invoices : Any)] : Any
  (let [invoiced-order-ids (mapv invoice-order-id invoices)]
    (filterv (fn [o]
               (not (some (fn [ioid] (= (orderid-value (ord/order-id o)) (orderid-value ioid)))
                          invoiced-order-ids)))
             orders)))

(defn invoices-without-orders [(invoices : Any) (orders : Any)] : Any
  (filterv (fn [inv]
             (nil? (ord/find-order-by-id orders (invoice-order-id inv))))
           invoices))

(defn duplicate-invoices-for-order [(invoices : Any) (order-id : ord/OrderId)] : Any
  (let [matches (invoices-for-order invoices order-id)]
    (if (> (count matches) 1) matches [])))

;; =============================================================================
;; Billing summary / dashboard
;; =============================================================================

(defn billing-summary [(invoices : Any) (payments : Any)
                        (credits : Any) (now : ord/Timestamp)] : Any
  (let [total-billed   (reduce (fn [acc inv] (+ acc (amount-value (invoice-total inv))))
                                0 invoices)
        collected      (total-revenue-collected payments)
        outstanding    (total-outstanding invoices payments)
        overdue-amt    (overdue-total invoices now)
        refunded       (total-refunded payments)
        credited       (total-credits-issued credits)
        inv-count      (count invoices)
        paid-count     (count (paid-invoices invoices))
        unpaid-count   (count (unpaid-invoices invoices))
        overdue-count  (count (overdue-invoices invoices now))]
    {:total-billed total-billed
     :total-collected collected
     :total-outstanding outstanding
     :total-overdue overdue-amt
     :total-refunded refunded
     :total-credits credited
     :invoice-count inv-count
     :paid-count paid-count
     :unpaid-count unpaid-count
     :overdue-count overdue-count
     :collection-rate (collection-rate-pct invoices payments)
     :health-score (portfolio-health invoices payments now)}))

(defn customer-billing-snapshot [(invoices : Any) (payments : Any)
                                  (credits : Any)
                                  (customer-id : cust/CustomerId) (now : ord/Timestamp)] : Any
  (let [billed      (customer-total-billed invoices customer-id)
        paid        (customer-total-paid payments invoices customer-id)
        outstanding (customer-outstanding-balance invoices payments customer-id)
        credit-amt  (total-credits-for-customer credits customer-id)
        net-pos     (customer-net-position invoices payments credits customer-id)
        inv-cnt     (customer-invoice-count invoices customer-id)
        unpaid-cnt  (customer-unpaid-count invoices customer-id)
        velocity    (customer-payment-velocity invoices customer-id)]
    {:customer-id customer-id
     :total-billed billed
     :total-paid paid
     :outstanding outstanding
     :credits credit-amt
     :net-position net-pos
     :invoice-count inv-cnt
     :unpaid-count unpaid-cnt
     :avg-days-to-pay velocity}))

;; =============================================================================
;; Method breakdown analytics
;; =============================================================================

(defn method-payment-count-map [(payments : Any)] : Any
  (let [completed (filterv (fn [p] (= (payment-status p) "completed")) payments)]
    (reduce (fn [acc p]
              (let [m   (payment-method p)
                    cur (get acc m)
                    old (if (nil? cur) 0 cur)]
                (assoc acc m (+ old 1))))
            {} completed)))

(defn method-avg-payment [(payments : Any) (method : String)] : Long
  (let [matching (filterv (fn [p] (and (= (payment-method p) method)
                                       (= (payment-status p) "completed")))
                          payments)
        cnt (count matching)]
    (if (= cnt 0) 0
        (quot (reduce (fn [acc p] (+ acc (amount-value (payment-amount p)))) 0 matching)
              cnt))))

;; =============================================================================
;; Write-off helpers
;; =============================================================================

(defn candidates-for-write-off [(invoices : Any) (payments : Any)
                                 (now : ord/Timestamp)
                                 (threshold-days : Long)] : Any
  (filterv (fn [inv]
             (and (= (invoice-status inv) "unpaid")
                  (> (invoice-age-days inv now) threshold-days)
                  (= (total-payments-for-invoice payments (invoice-id inv)) 0)))
           invoices))

(defn write-off-exposure [(invoices : Any) (payments : Any)
                           (now : ord/Timestamp) (threshold-days : Long)] : Long
  (reduce (fn [acc inv] (+ acc (amount-value (invoice-total inv))))
          0
          (candidates-for-write-off invoices payments now threshold-days)))

(defn partial-payment-invoices [(invoices : Any) (payments : Any)] : Any
  (filterv (fn [inv]
             (let [bal (invoice-balance inv payments)
                   tot (amount-value (invoice-total inv))]
               (and (> bal 0) (< bal tot))))
           invoices))

;; =============================================================================
;; Statement generation
;; =============================================================================

(defn customer-statement-lines [(invoices : Any) (payments : Any)
                                 (customer-id : cust/CustomerId)] : Any
  (let [cust-invs (sort-invoices-by-date
                    (invoices-for-customer invoices customer-id))]
    (mapv (fn [inv]
            (let [bal (invoice-balance inv payments)]
              (str "Invoice #" (invoiceid-value (invoice-id inv))
                   " | Issued: " (timestamp-value (invoice-issued-at inv))
                   " | Due: " (timestamp-value (invoice-due-at inv))
                   " | Total: " (cat/format-price (->Price (amount-value (invoice-total inv))))
                   " | Paid: " (cat/format-price (->Price (- (amount-value (invoice-total inv)) bal)))
                   " | Balance: " (cat/format-price (->Price bal))
                   " | Status: " (invoice-status inv))))
          cust-invs)))

(defn payment-receipt [(p : Payment)] : String
  (str "=== Payment Receipt ==="
       "\nPayment ID: " (paymentid-value (payment-id p))
       "\nInvoice: #" (invoiceid-value (payment-invoice-id p))
       "\nAmount: " (cat/format-price (->Price (amount-value (payment-amount p))))
       "\nMethod: " (payment-method p)
       "\nStatus: " (payment-status p)
       "\nProcessed: " (timestamp-value (payment-processed-at p))
       "\n========================"))
