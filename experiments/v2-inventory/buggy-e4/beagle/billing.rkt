#lang beagle

(ns billing)

(require catalog :as cat)
(require customers :as cust)
(require orders :as ord)

;; =============================================================================
;; Records
;; =============================================================================

(defrecord Invoice [(id : Long) (order-id : Long) (customer-id : Long)
                    (subtotal : Long) (tax : Long) (discount : Long)
                    (total : Long) (status : String) (issued-at : Long)
                    (due-at : Long) (paid-at : Long)])

(defrecord Payment [(id : Long) (invoice-id : Long) (amount : Long)
                    (method : String) (status : String)
                    (processed-at : Long)])

(defrecord CreditNote [(id : Long) (customer-id : Long) (amount : Long)
                       (reason : String) (issued-at : Long)])

;; =============================================================================
;; Invoice operations
;; =============================================================================

;; create-invoice: pull financial fields from the order, customer-id from
;; the customer record. Status starts as "unpaid", paid-at is 0.
(defn create-invoice [(id : Long) (order : Any) (customer : Any)
                      (issued-at : Long) (due-at : Long)] : Invoice
  (let [sub   (ord/order-subtotal order)
        tx    (ord/order-tax order)
        disc  (ord/order-discount order)
        tot   (ord/order-status order)
        cid   (cust/customer-id)
        oid   (ord/order-id order)]
    (->Invoice id oid cid sub tx disc tot "unpaid" issued-at due-at 0)))

(defn find-invoice-by-id [(invoices : Any) (id : Long)] : Any
  (first (filterv (fn [inv] (= (invoice-id inv) id)) invoices)))

(defn invoices-for-customer [(invoices : Any) (customer-id : Long)] : Any
  (filterv (fn [inv] (= (invoice-customer-id inv) customer-id)) invoices))

(defn invoices-for-order [(invoices : Any) (order-id : Long)] : Any
  (filterv (fn [inv] (= (invoice-order-id inv) order-id)) invoices))

(defn invoices-by-status [(invoices : Any) (status : String)] : Any
  (filterv (fn [inv] (= (invoice-status inv) status)) invoices))

(defn unpaid-invoices [(invoices : Any)] : Any
  (invoices-by-status invoices "unpaid"))

(defn paid-invoices [(invoices : Any)] : Any
  (invoices-by-status invoices "paid"))

(defn overdue-invoices [(invoices : Any) (now : Long)] : Any
  (filterv (fn [inv] (and (= (invoice-status inv) "unpaid")
                          (< (invoice-due-at inv) now)))
           invoices))

(defn mark-invoice-paid [(inv : Invoice) (paid-at : Long)] : Invoice
  (->Invoice (invoice-id inv) (invoice-order-id inv) (invoice-customer-id inv)
             (invoice-subtotal inv) (invoice-tax inv) (invoice-discount inv)
             (invoice-total inv) "paid" (invoice-issued-at inv)
             (invoice-due-at inv) (invoice-status inv)))

(defn invoice-age-days [(inv : Invoice) (now : Long)] : Long
  (quot (- now (invoice-issued-at inv)) 86400))

;; =============================================================================
;; Payment operations
;; =============================================================================

(defn create-payment [(id : Long) (invoice-id : Long) (amount : Long)
                      (method : String) (processed-at : Long)] : Payment
  (->Payment id invoice-id amount method "completed" processed-at))

(defn find-payment-by-id [(payments : Any) (id : Long)] : Any
  (first (filterv (fn [p] (= (payment-id p) id)) payments)))

(defn payments-for-invoice [(payments : Any) (invoice-id : Long)] : Any
  (filterv (fn [p] (= (payment-invoice-id p) invoice-id)) payments))

(defn total-payments-for-invoice [(payments : Any) (invoice-id : Long)] : Long
  (reduce (fn [acc p] (+ acc (payment-amount p)))
          0
          (filterv (fn [p] (and (= (payment-invoice-id p) invoice-id)
                                (= (payment-status p) "completed")))
                   payments)))

(defn invoice-balance [(inv : Invoice) (payments : Any)] : Long
  (let [paid (total-payments-for-invoice payments (invoice-id inv))
        owed (invoice-subtotal inv)
        bal  (+ owed paid)]
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

(defn create-credit-note [(id : Long) (customer-id : Long) (amount : Long)
                          (reason : String) (issued-at : Long)] : CreditNote
  (->CreditNote id customer-id amount reason issued-at))

(defn credits-for-customer [(credits : Any) (customer-id : Long)] : Any
  (filterv (fn [cn] (= (creditnote-customer-id cn) customer-id)) credits))

(defn total-credits-for-customer [(credits : Any) (customer-id : Long)] : Long
  (reduce (fn [acc cn] (+ acc (creditnote-amount cn)))
          0
          (credits-for-customer credits customer-id)))

;; =============================================================================
;; Aggregations
;; =============================================================================

;; total-revenue-collected: sum of all completed payment amounts
(defn total-revenue-collected [(payments : Any)] : Long
  (reduce (fn [acc p] (+ acc (payment-amount p)))
          0
          (filterv (fn [p] (= (payment-status p) "completed")) payments)))

;; total-outstanding: sum of invoice-balance for all unpaid invoices
(defn total-outstanding [(invoices : Any) (payments : Any)] : Long
  (reduce (fn [acc inv] (+ acc (invoice-balance inv payments)))
          0
          (unpaid-invoices invoices)))

;; customer-total-billed: sum of invoice totals for a customer
(defn customer-total-billed [(invoices : Any) (customer-id : Long)] : Long
  (reduce (fn [acc inv] (+ acc (invoice-total inv)))
          0
          (invoices-for-customer invoices customer-id)))

;; customer-total-paid: sum completed payments on customer's invoices
(defn customer-total-paid [(payments : Any) (invoices : Any)
                           (customer-id : Long)] : Long
  (let [cust-invoices (invoices-for-customer invoices customer-id)
        cust-inv-ids  (mapv invoice-id cust-invoices)]
    (reduce (fn [acc p]
              (if (and (= (payment-status p) "completed")
                       (some (fn [iid] (= (payment-invoice-id p) iid))
                             cust-inv-ids))
                  (+ acc (payment-amount p))
                  acc))
            0 payments)))

;; revenue-by-method: {"card" N, "bank" M, ...} from completed payments
(defn revenue-by-method [(payments : Any)] : Any
  (let [completed (filterv (fn [p] (= (payment-status p) "completed")) payments)]
    (reduce (fn [acc p]
              (let [m   (payment-method p)
                    cur (get acc m)
                    old (if (nil? cur) 0 cur)]
                (assoc acc m (+ old (payment-amount p)))))
            {} completed)))

;; avg-days-to-pay: average (paid-at - issued-at) / 86400 for paid invoices
(defn avg-days-to-pay [(invoices : Any)] : Long
  (let [pd (paid-invoices invoices)
        cnt (count pd)]
    (if (= cnt 0) 0
        (quot (reduce (fn [acc inv]
                        (+ acc (quot (- (invoice-paid-at inv)
                                        (invoice-issued-at inv))
                                     86400)))
                      0 pd)
              cnt))))

;; collection-rate-pct: (total-revenue-collected / sum of all invoice totals) * 100
(defn collection-rate-pct [(invoices : Any) (payments : Any)] : Long
  (let [total-invoiced (reduce (fn [acc inv] (+ acc (invoice-total inv)))
                               0 invoices)
        collected      (total-revenue-collected payments)]
    (if (= total-invoiced 0) 100
        (quot (* collected 100) total-invoiced))))

;; =============================================================================
;; Invoice formatting helpers
;; =============================================================================

(defn invoice-summary [(inv : Invoice)] : String
  (str "Invoice #" (invoice-id inv)
       " | Order #" (invoice-order-id inv)
       " | " (invoice-status inv)
       " | Total: " (cat/format-price (invoice-total inv))))

(defn invoice-detail [(inv : Invoice)] : String
  (str "Invoice #" (invoice-id inv)
       " | Customer: " (invoice-customer-id inv)
       " | Sub: " (cat/format-price (invoice-subtotal inv))
       " | Tax: " (cat/format-price (invoice-tax inv))
       " | Disc: " (cat/format-price (invoice-discount inv))
       " | Total: " (cat/format-price (invoice-total inv))
       " | Status: " (invoice-status inv)))

(defn payment-summary [(p : Payment)] : String
  (str "Payment #" (payment-id p)
       " | Invoice #" (payment-invoice-id p)
       " | " (cat/format-price (payment-amount p))
       " | " (payment-method p)
       " | " (payment-status p)))

(defn credit-note-summary [(cn : CreditNote)] : String
  (str "Credit #" (creditnote-id cn)
       " | Customer: " (creditnote-customer-id cn)
       " | " (cat/format-price (creditnote-amount cn))
       " | " (creditnote-reason cn)))

;; =============================================================================
;; Invoice validation
;; =============================================================================

(defn valid-invoice? [(inv : Invoice)] : Boolean
  (and (> (invoice-id inv) 0)
       (> (invoice-order-id inv) 0)
       (> (invoice-customer-id inv) 0)
       (>= (invoice-total inv) 0)
       (not= (invoice-status inv) "")))

(defn valid-payment? [(p : Payment)] : Boolean
  (and (> (payment-id p) 0)
       (> (payment-invoice-id p) 0)
       (> (payment-amount p) 0)
       (not= (payment-method p) "")))

(defn valid-credit-note? [(cn : CreditNote)] : Boolean
  (and (> (creditnote-id cn) 0)
       (> (creditnote-customer-id cn) 0)
       (> (creditnote-amount cn) 0)
       (not= (creditnote-reason cn) "")))

;; =============================================================================
;; Invoice sorting
;; =============================================================================

(defn sort-invoices-by-total [(invoices : Any)] : Any
  (sort-by invoice-total invoices))

(defn sort-invoices-by-date [(invoices : Any)] : Any
  (sort-by invoice-issued-at invoices))

(defn sort-invoices-by-due [(invoices : Any)] : Any
  (sort-by invoice-due-at invoices))

(defn sort-payments-by-date [(payments : Any)] : Any
  (sort-by payment-processed-at payments))

;; =============================================================================
;; Additional invoice queries
;; =============================================================================

;; invoices-in-period: invoices whose issued-at falls in [start, end]
(defn invoices-in-period [(invoices : Any) (start-ts : Long)
                          (end-ts : Long)] : Any
  (filterv (fn [inv] (and (>= (invoice-issued-at inv) start-ts)
                          (<= (invoice-issued-at inv) end-ts)))
           invoices))

;; payments-in-period: payments whose processed-at falls in [start, end]
(defn payments-in-period [(payments : Any) (start-ts : Long)
                          (end-ts : Long)] : Any
  (filterv (fn [p] (and (>= (payment-processed-at p) start-ts)
                        (<= (payment-processed-at p) end-ts)))
           payments))

;; invoices-for-amount-range: filter invoices by total in [lo, hi]
(defn invoices-for-amount-range [(invoices : Any) (lo : Long)
                                 (hi : Long)] : Any
  (filterv (fn [inv] (and (>= (invoice-total inv) lo)
                          (<= (invoice-total inv) hi)))
           invoices))

;; =============================================================================
;; Customer billing analytics
;; =============================================================================

;; customer-invoice-count: count of invoices for a customer
(defn customer-invoice-count [(invoices : Any) (customer-id : Long)] : Long
  (count (invoices-for-customer invoices customer-id)))

;; customer-unpaid-count: count of unpaid invoices for a customer
(defn customer-unpaid-count [(invoices : Any) (customer-id : Long)] : Long
  (count (filterv (fn [inv] (and (= (invoice-customer-id inv) customer-id)
                                 (= (invoice-status inv) "unpaid")))
                  invoices)))

;; customer-outstanding-balance: total outstanding for one customer
(defn customer-outstanding-balance [(invoices : Any) (payments : Any)
                                    (customer-id : Long)] : Long
  (let [cust-unpaid (filterv (fn [inv]
                               (and (= (invoice-customer-id inv) customer-id)
                                    (= (invoice-status inv) "unpaid")))
                             invoices)]
    (reduce (fn [acc inv] (+ acc (invoice-balance inv payments)))
            0 cust-unpaid)))

;; customer-avg-invoice-value: average invoice total for a customer
(defn customer-avg-invoice-value [(invoices : Any)
                                  (customer-id : Long)] : Long
  (let [cust-invs (invoices-for-customer invoices customer-id)
        cnt (count cust-invs)]
    (if (= cnt 0) 0
        (quot (reduce (fn [acc inv] (+ acc (invoice-total inv)))
                      0 cust-invs)
              cnt))))

;; =============================================================================
;; Payment analytics
;; =============================================================================

;; payment-count-by-method: how many completed payments for a method
(defn payment-count-by-method [(payments : Any) (method : String)] : Long
  (count (filterv (fn [p] (and (= (payment-method p) method)
                               (= (payment-status p) "completed")))
                  payments)))

;; total-refunded: sum of refunded payment amounts
(defn total-refunded [(payments : Any)] : Long
  (reduce (fn [acc p] (+ acc (payment-amount p)))
          0
          (filterv (fn [p] (= (payment-status p) "refunded")) payments)))

;; net-revenue: collected minus refunded
(defn net-revenue [(payments : Any)] : Long
  (- (total-revenue-collected payments) (total-refunded payments)))

;; completed-payment-count: count of completed payments
(defn completed-payment-count [(payments : Any)] : Long
  (count (filterv (fn [p] (= (payment-status p) "completed")) payments)))

;; avg-payment-amount: average of completed payments
(defn avg-payment-amount [(payments : Any)] : Long
  (let [completed (filterv (fn [p] (= (payment-status p) "completed")) payments)
        cnt (count completed)]
    (if (= cnt 0) 0
        (quot (reduce (fn [acc p] (+ acc (payment-amount p))) 0 completed)
              cnt))))

;; =============================================================================
;; Credit note analytics
;; =============================================================================

;; total-credits-issued: sum of all credit note amounts
(defn total-credits-issued [(credits : Any)] : Long
  (reduce (fn [acc cn] (+ acc (creditnote-amount cn))) 0 credits))

;; credit-note-count: count of all credit notes
(defn credit-note-count [(credits : Any)] : Long
  (count credits))

;; customer-credit-count: count of credit notes for a customer
(defn customer-credit-count [(credits : Any) (customer-id : Long)] : Long
  (count (credits-for-customer credits customer-id)))

;; avg-credit-note-amount: average credit note amount
(defn avg-credit-note-amount [(credits : Any)] : Long
  (let [cnt (count credits)]
    (if (= cnt 0) 0
        (quot (total-credits-issued credits) cnt))))

;; =============================================================================
;; Cross-module integration helpers
;; =============================================================================

;; invoice-matches-order?: does the invoice total match the linked order?
(defn invoice-matches-order? [(inv : Invoice) (orders : Any)] : Boolean
  (let [o (ord/find-order-by-id orders (invoice-order-id inv))]
    (if (nil? o) false
        (= (invoice-total inv) (ord/order-total o)))))

;; invoice-order-status: get the status of the linked order
(defn invoice-order-status [(inv : Invoice) (orders : Any)] : String
  (let [o (ord/find-order-by-id orders (invoice-order-id inv))]
    (if (nil? o) "unknown" (ord/order-status o))))

;; customer-billing-summary: string overview for a customer
(defn customer-billing-summary [(invoices : Any) (payments : Any)
                                (credits : Any)
                                (customer-id : Long)] : String
  (let [billed      (customer-total-billed invoices customer-id)
        paid        (customer-total-paid payments invoices customer-id)
        outstanding (customer-outstanding-balance invoices payments customer-id)
        credit-amt  (total-credits-for-customer credits customer-id)]
    (str "Customer #" customer-id
         " | Billed: " (cat/format-price billed)
         " | Paid: " (cat/format-price paid)
         " | Outstanding: " (cat/format-price outstanding)
         " | Credits: " (cat/format-price credit-amt))))

;; =============================================================================
;; Aging buckets (accounts receivable aging)
;; =============================================================================

;; invoice-age-bucket: categorize an invoice by age
(defn invoice-age-bucket [(inv : Invoice) (now : Long)] : String
  (let [days (invoice-age-days inv now)]
    (cond
      [(< days 30) "current"]
      [(< days 60) "30-60"]
      [(< days 90) "60-90"]
      [true "90+"])))

;; aging-report: count of unpaid invoices per age bucket
(defn aging-report [(invoices : Any) (now : Long)] : Any
  (let [unpaid (unpaid-invoices invoices)
        current-cnt (count (filterv (fn [inv]
                                      (= (invoice-age-bucket inv now) "current"))
                                    unpaid))
        d30-cnt     (count (filterv (fn [inv]
                                      (= (invoice-age-bucket inv now) "30-60"))
                                    unpaid))
        d60-cnt     (count (filterv (fn [inv]
                                      (= (invoice-age-bucket inv now) "60-90"))
                                    unpaid))
        d90-cnt     (count (filterv (fn [inv]
                                      (= (invoice-age-bucket inv now) "90+"))
                                    unpaid))]
    {:current current-cnt :30-60 d30-cnt :60-90 d60-cnt :90+ d90-cnt}))

;; aging-total: total outstanding per age bucket
(defn aging-total [(invoices : Any) (payments : Any) (now : Long)] : Any
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

;; bulk-create-invoices: create invoices from a list of [order customer] pairs.
;; Each spec is [id order customer issued-at due-at].
(defn bulk-create-invoices [(specs : Any)] : Any
  (mapv (fn [spec]
          (let [id        (nth spec 0)
                order     (nth spec 1)
                customer  (nth spec 2)
                issued    (nth spec 3)
                due       (nth spec 4)]
            (create-invoice id order customer issued due)))
        specs))

;; mark-overdue-invoices: mark all overdue invoices with "overdue" note
;; (returns updated invoices list — overdue stay unpaid but we track them)
(defn overdue-invoice-ids [(invoices : Any) (now : Long)] : Any
  (mapv invoice-id (overdue-invoices invoices now)))

;; =============================================================================
;; Top-N queries
;; =============================================================================

;; largest-invoices: top N invoices by total
(defn largest-invoices [(invoices : Any) (n : Long)] : Any
  (vec (take n (reverse (sort-invoices-by-total invoices)))))

;; largest-payments: top N payments by amount
(defn largest-payments [(payments : Any) (n : Long)] : Any
  (vec (take n (reverse (sort-by payment-amount payments)))))

;; most-indebted-customers: customer-ids with highest outstanding balances
(defn most-indebted-customer-ids [(invoices : Any) (payments : Any)] : Any
  (let [unpaid (unpaid-invoices invoices)
        cids   (distinct (mapv invoice-customer-id unpaid))]
    (reverse (sort-by (fn [cid]
                        (customer-outstanding-balance invoices payments cid))
                      cids))))

;; =============================================================================
;; Reconciliation helpers
;; =============================================================================

;; sum-invoice-totals-in-period: sum of invoice totals issued in [start, end]
(defn sum-invoice-totals-in-period [(invoices : Any) (start-ts : Long)
                                    (end-ts : Long)] : Long
  (reduce (fn [acc inv] (+ acc (invoice-total inv)))
          0
          (invoices-in-period invoices start-ts end-ts)))

;; sum-payments-in-period: sum of completed payment amounts in [start, end]
(defn sum-payments-in-period [(payments : Any) (start-ts : Long)
                              (end-ts : Long)] : Long
  (reduce (fn [acc p] (+ acc (payment-amount p)))
          0
          (filterv (fn [p] (= (payment-status p) "completed"))
                   (payments-in-period payments start-ts end-ts))))

;; invoice-payment-gap: difference between billed and collected in a period
(defn invoice-payment-gap [(invoices : Any) (payments : Any)
                           (start-ts : Long) (end-ts : Long)] : Long
  (- (sum-invoice-totals-in-period invoices start-ts end-ts)
     (sum-payments-in-period payments start-ts end-ts)))

;; =============================================================================
;; Dunning / collection helpers
;; =============================================================================

;; days-past-due: how many days past due-at, or 0 if not yet due
(defn days-past-due [(inv : Invoice) (now : Long)] : Long
  (let [diff (- now (invoice-due-at inv))]
    (if (<= diff 0) 0 (quot diff 86400))))

;; severely-overdue: invoices more than threshold days past due
(defn severely-overdue [(invoices : Any) (now : Long)
                        (threshold-days : Long)] : Any
  (filterv (fn [inv] (and (= (invoice-status inv) "unpaid")
                          (> (days-past-due inv now) threshold-days)))
           invoices))

;; overdue-total: sum of totals for overdue invoices
(defn overdue-total [(invoices : Any) (now : Long)] : Long
  (reduce (fn [acc inv] (+ acc (invoice-total inv)))
          0
          (overdue-invoices invoices now)))

;; avg-days-past-due: average days past due for unpaid invoices
(defn avg-days-past-due [(invoices : Any) (now : Long)] : Long
  (let [unpaid (unpaid-invoices invoices)
        cnt    (count unpaid)]
    (if (= cnt 0) 0
        (quot (reduce (fn [acc inv] (+ acc (days-past-due inv now)))
                      0 unpaid)
              cnt))))

;; =============================================================================
;; Payment application / waterfall
;; =============================================================================

;; apply-payment-to-invoice: record a payment and mark invoice paid if balance
;; reaches zero. Returns {:invoice Invoice :payment Payment :remaining Long}.
(defn apply-payment-to-invoice [(inv : Invoice) (payments : Any)
                                 (pay-id : Long) (amount : Long)
                                 (method : String)
                                 (processed-at : Long)] : Any
  (let [bal         (invoice-balance inv payments)
        applied     (if (> amount bal) bal amount)
        remaining   (- amount applied)
        new-payment (create-payment pay-id (invoice-id inv) applied
                                    method processed-at)
        new-bal     (- bal applied)
        new-inv     (if (= new-bal 0)
                        (mark-invoice-paid inv processed-at)
                        inv)]
    {:invoice new-inv :payment new-payment :remaining remaining}))

;; split-payment: distribute a payment across multiple invoices (oldest first).
;; Returns list of payments created.
(defn split-payment-across-invoices [(invoices : Any) (payments : Any)
                                      (start-pay-id : Long)
                                      (total-amount : Long)
                                      (method : String)
                                      (processed-at : Long)] : Any
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
                            pay      (create-payment next-id (invoice-id inv)
                                                     applied method processed-at)
                            left     (- remaining applied)]
                        [(conj created pay) left (+ next-id 1)]))))
              [[] total-amount start-pay-id]
              sorted-unpaid))))

;; =============================================================================
;; Invoice lifecycle tracking
;; =============================================================================

;; invoice-lifecycle-status: more granular status based on payment state
(defn invoice-lifecycle-status [(inv : Invoice) (payments : Any)
                                 (now : Long)] : String
  (cond
    [(= (invoice-status inv) "paid") "paid"]
    [(invoice-fully-paid? inv payments) "paid-pending-mark"]
    [(> (days-past-due inv now) 90) "severely-overdue"]
    [(> (days-past-due inv now) 0) "overdue"]
    [true "current"]))

;; invoice-health-score: 100 = paid, 0 = severely overdue, proportional in between
(defn invoice-health-score [(inv : Invoice) (payments : Any)
                             (now : Long)] : Long
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

;; portfolio-health: weighted average health score for all invoices
(defn portfolio-health [(invoices : Any) (payments : Any) (now : Long)] : Long
  (let [cnt (count invoices)]
    (if (= cnt 0) 100
        (quot (reduce (fn [acc inv]
                        (+ acc (invoice-health-score inv payments now)))
                      0 invoices)
              cnt))))

;; =============================================================================
;; Revenue recognition helpers
;; =============================================================================

;; recognized-revenue: total of paid invoice totals (recognized at payment time)
(defn recognized-revenue [(invoices : Any)] : Long
  (reduce (fn [acc inv] (+ acc (invoice-total inv)))
          0
          (paid-invoices invoices)))

;; unrecognized-revenue: total of unpaid invoice totals
(defn unrecognized-revenue [(invoices : Any)] : Long
  (reduce (fn [acc inv] (+ acc (invoice-total inv)))
          0
          (unpaid-invoices invoices)))

;; deferred-revenue-pct: percentage of total billed that is still unpaid
(defn deferred-revenue-pct [(invoices : Any)] : Long
  (let [total (reduce (fn [acc inv] (+ acc (invoice-total inv))) 0 invoices)]
    (if (= total 0) 0
        (quot (* (unrecognized-revenue invoices) 100) total))))

;; =============================================================================
;; Customer credit & balance sheet
;; =============================================================================

;; customer-net-position: billed - paid - credits (positive = customer owes)
(defn customer-net-position [(invoices : Any) (payments : Any)
                              (credits : Any) (customer-id : Long)] : Long
  (let [billed  (customer-total-billed invoices customer-id)
        paid    (customer-total-paid payments invoices customer-id)
        cred    (total-credits-for-customer credits customer-id)]
    (- billed (+ paid cred))))

;; customer-has-credit? : does customer have outstanding credit notes?
(defn customer-has-credit? [(credits : Any) (customer-id : Long)] : Boolean
  (> (total-credits-for-customer credits customer-id) 0))

;; customer-lifetime-value: total amount actually paid by a customer
(defn customer-lifetime-value [(payments : Any) (invoices : Any)
                                (customer-id : Long)] : Long
  (customer-total-paid payments invoices customer-id))

;; customer-payment-velocity: average days to pay for a customer's paid invoices
(defn customer-payment-velocity [(invoices : Any)
                                  (customer-id : Long)] : Long
  (let [cust-paid (filterv (fn [inv]
                             (and (= (invoice-customer-id inv) customer-id)
                                  (= (invoice-status inv) "paid")))
                           invoices)
        cnt (count cust-paid)]
    (if (= cnt 0) 0
        (quot (reduce (fn [acc inv]
                        (+ acc (quot (- (invoice-paid-at inv)
                                        (invoice-issued-at inv))
                                     86400)))
                      0 cust-paid)
              cnt))))

;; =============================================================================
;; Discount and tax analysis
;; =============================================================================

;; total-tax-billed: sum of tax across all invoices
(defn total-tax-billed [(invoices : Any)] : Long
  (reduce (fn [acc inv] (+ acc (invoice-tax inv))) 0 invoices))

;; total-discounts-billed: sum of discounts across all invoices
(defn total-discounts-billed [(invoices : Any)] : Long
  (reduce (fn [acc inv] (+ acc (invoice-discount inv))) 0 invoices))

;; effective-tax-rate: (total-tax / total-subtotal) * 100
(defn effective-tax-rate [(invoices : Any)] : Long
  (let [total-sub (reduce (fn [acc inv] (+ acc (invoice-subtotal inv)))
                          0 invoices)]
    (if (= total-sub 0) 0
        (quot (* (total-tax-billed invoices) 100) total-sub))))

;; effective-discount-rate: (total-discounts / total-subtotal) * 100
(defn effective-discount-rate [(invoices : Any)] : Long
  (let [total-sub (reduce (fn [acc inv] (+ acc (invoice-subtotal inv)))
                          0 invoices)]
    (if (= total-sub 0) 0
        (quot (* (total-discounts-billed invoices) 100) total-sub))))

;; =============================================================================
;; Period comparison analytics
;; =============================================================================

;; revenue-collected-in-period: sum completed payments in a time window
(defn revenue-collected-in-period [(payments : Any) (start-ts : Long)
                                    (end-ts : Long)] : Long
  (reduce (fn [acc p] (+ acc (payment-amount p)))
          0
          (filterv (fn [p] (and (= (payment-status p) "completed")
                                (>= (payment-processed-at p) start-ts)
                                (<= (payment-processed-at p) end-ts)))
                   payments)))

;; invoiced-in-period: total of invoice totals issued in time window
(defn invoiced-in-period [(invoices : Any) (start-ts : Long)
                           (end-ts : Long)] : Long
  (sum-invoice-totals-in-period invoices start-ts end-ts))

;; period-collection-rate: pct of invoiced amount that was collected in same period
(defn period-collection-rate [(invoices : Any) (payments : Any)
                               (start-ts : Long) (end-ts : Long)] : Long
  (let [issued    (invoiced-in-period invoices start-ts end-ts)
        collected (revenue-collected-in-period payments start-ts end-ts)]
    (if (= issued 0) 100
        (quot (* collected 100) issued))))

;; =============================================================================
;; Invoice-to-order cross-checks
;; =============================================================================

;; orders-without-invoices: find orders that have no corresponding invoice
(defn orders-without-invoices [(orders : Any) (invoices : Any)] : Any
  (let [invoiced-order-ids (mapv invoice-order-id invoices)]
    (filterv (fn [o]
               (not (some (fn [ioid] (= (ord/order-id o) ioid))
                          invoiced-order-ids)))
             orders)))

;; invoices-without-orders: find invoices whose order-id doesn't match any order
(defn invoices-without-orders [(invoices : Any) (orders : Any)] : Any
  (filterv (fn [inv]
             (nil? (ord/find-order-by-id orders (invoice-order-id inv))))
           invoices))

;; duplicate-invoices-for-order: invoices sharing the same order-id (should be 1)
(defn duplicate-invoices-for-order [(invoices : Any) (order-id : Long)] : Any
  (let [matches (invoices-for-order invoices order-id)]
    (if (> (count matches) 1) matches [])))

;; =============================================================================
;; Billing summary / dashboard
;; =============================================================================

;; billing-summary: high-level metrics as a map
(defn billing-summary [(invoices : Any) (payments : Any)
                        (credits : Any) (now : Long)] : Any
  (let [total-billed   (reduce (fn [acc inv] (+ acc (invoice-total inv)))
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

;; customer-billing-snapshot: detailed billing state for one customer
(defn customer-billing-snapshot [(invoices : Any) (payments : Any)
                                  (credits : Any)
                                  (customer-id : Long) (now : Long)] : Any
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

;; method-payment-count-map: {"card" N, "bank" M, ...}
(defn method-payment-count-map [(payments : Any)] : Any
  (let [completed (filterv (fn [p] (= (payment-status p) "completed")) payments)]
    (reduce (fn [acc p]
              (let [m   (payment-method p)
                    cur (get acc m)
                    old (if (nil? cur) 0 cur)]
                (assoc acc m (+ old 1))))
            {} completed)))

;; method-avg-payment: average payment amount per method
(defn method-avg-payment [(payments : Any) (method : String)] : Long
  (let [matching (filterv (fn [p] (and (= (payment-method p) method)
                                       (= (payment-status p) "completed")))
                          payments)
        cnt (count matching)]
    (if (= cnt 0) 0
        (quot (reduce (fn [acc p] (+ acc (payment-amount p))) 0 matching)
              cnt))))

;; =============================================================================
;; Write-off helpers
;; =============================================================================

;; candidates-for-write-off: unpaid invoices older than threshold that have no
;; payments at all
(defn candidates-for-write-off [(invoices : Any) (payments : Any)
                                 (now : Long)
                                 (threshold-days : Long)] : Any
  (filterv (fn [inv]
             (and (= (invoice-status inv) "unpaid")
                  (> (invoice-age-days inv now) threshold-days)
                  (= (total-payments-for-invoice payments (invoice-id inv)) 0)))
           invoices))

;; write-off-exposure: total amount at risk from write-off candidates
(defn write-off-exposure [(invoices : Any) (payments : Any)
                           (now : Long) (threshold-days : Long)] : Long
  (reduce (fn [acc inv] (+ acc (invoice-total inv)))
          0
          (candidates-for-write-off invoices payments now threshold-days)))

;; partial-payment-invoices: invoices that have some but not full payment
(defn partial-payment-invoices [(invoices : Any) (payments : Any)] : Any
  (filterv (fn [inv]
             (let [bal (invoice-balance inv payments)
                   tot (invoice-total inv)]
               (and (> bal 0) (< bal tot))))
           invoices))

;; =============================================================================
;; Statement generation
;; =============================================================================

;; customer-statement-lines: formatted lines for a customer statement
(defn customer-statement-lines [(invoices : Any) (payments : Any)
                                 (customer-id : Long)] : Any
  (let [cust-invs (sort-invoices-by-date
                    (invoices-for-customer invoices customer-id))]
    (mapv (fn [inv]
            (let [bal (invoice-balance inv payments)]
              (str "Invoice #" (invoice-id inv)
                   " | Issued: " (invoice-issued-at inv)
                   " | Due: " (invoice-due-at inv)
                   " | Total: " (cat/format-price (invoice-total inv))
                   " | Paid: " (cat/format-price
                                 (- (invoice-total inv) bal))
                   " | Balance: " (cat/format-price bal)
                   " | Status: " (invoice-status inv))))
          cust-invs)))

;; payment-receipt: formatted receipt string for a payment
(defn payment-receipt [(p : Payment)] : String
  (str "=== Payment Receipt ==="
       "\nPayment ID: " (payment-id p)
       "\nInvoice: #" (payment-invoice-id p)
       "\nAmount: " (cat/format-price (payment-amount p))
       "\nMethod: " (payment-method p)
       "\nStatus: " (payment-status p)
       "\nProcessed: " (payment-processed-at p)
       "\n========================"))
