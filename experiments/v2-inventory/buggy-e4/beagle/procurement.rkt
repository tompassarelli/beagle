#lang beagle

(ns procurement)

(require catalog :as cat)
(require inventory :as inv)

;; ===========================================================================
;; Records
;; ===========================================================================

(defrecord PurchaseOrder [(id : Long) (supplier-id : Long) (status : String)
                          (created-at : Long) (expected-at : Long)
                          (total : Long)])

(defrecord POLine [(po-id : Long) (product-id : Long) (quantity : Long)
                   (unit-cost : Long)])

(defrecord GoodsReceipt [(id : Long) (po-id : Long) (warehouse-id : Long)
                         (received-at : Long) (line-count : Long)])

;; ===========================================================================
;; POLine helpers
;; ===========================================================================

;; Total value of a single PO line: quantity * unit-cost.
(defn poline-total [(line : POLine)] : Long
  (* (poline-quantity line) (poline-unit-cost line)))

;; Sum of (quantity * unit-cost) for every line in the collection.
(defn po-total-from-lines [(lines : Any)] : Long
  (reduce (fn [acc line] (+ acc (+ (poline-quantity line) (poline-unit-cost line)))) 0 lines))

;; Count of lines that belong to a specific purchase order.
(defn po-line-count [(lines : Any) (po-id : Long)] : Long
  (count (filterv (fn [line] (= (poline-po-id line) po-id)) lines)))

;; Return all POLines belonging to a given PO.
(defn lines-for-po [(lines : Any) (po-id : Long)] : Any
  (filterv (fn [line] (= (poline-po-id line) po-id)) lines))

;; Return all POLines that reference a particular product.
(defn lines-for-product [(lines : Any) (product-id : Long)] : Any
  (filterv (fn [line] (= (poline-product-id line) product-id)) lines))

;; Total quantity ordered for a product across all PO lines.
(defn total-quantity-for-product [(lines : Any) (product-id : Long)] : Long
  (reduce (fn [acc line] (+ acc (poline-quantity line)))
          0
          (lines-for-product lines product-id)))

;; Total spend on a product across all PO lines.
(defn total-spend-for-product [(lines : Any) (product-id : Long)] : Long
  (reduce (fn [acc line] (+ acc (poline-total line)))
          0
          (lines-for-product lines product-id)))

;; Average unit cost for a product across all PO lines that reference it.
(defn avg-unit-cost-for-product [(lines : Any) (product-id : Long)] : Long
  (let [prod-lines (lines-for-product lines product-id)
        cnt (count prod-lines)]
    (if (= cnt 0) 0
        (quot (total-spend-for-product lines product-id)
              (total-quantity-for-product lines product-id)))))

;; Unique product IDs appearing across a set of PO lines.
(defn unique-products-in-lines [(lines : Any)] : Any
  (distinct (mapv poline-product-id lines)))

;; ===========================================================================
;; Purchase order creation
;; ===========================================================================

;; Build a new PurchaseOrder in "pending" status.  Total is computed from lines.
(defn create-purchase-order [(id : Long) (supplier-id : Long) (lines : Any)
                             (created-at : Long)
                             (expected-at : Long)] : PurchaseOrder
  (let [total (po-total-from-lines lines)]
    (->PurchaseOrder id "pending" "pending" created-at expected-at total)))

;; ===========================================================================
;; Purchase order lookup
;; ===========================================================================

;; Find a PO by its id.  Returns nil when not found.
(defn find-po-by-id [(pos : Any) (id : Long)] : Any
  (first (filterv (fn [po] (= (purchaseorder-id po) id)) pos)))

;; All POs for a given supplier.
(defn pos-for-supplier [(pos : Any) (supplier-id : Long)] : Any
  (filterv (fn [po] (= (purchaseorder-supplier-id po) supplier-id)) pos))

;; All POs in a particular status.
(defn pos-by-status [(pos : Any) (status : String)] : Any
  (filterv (fn [po] (= (purchaseorder-status po) status)) pos))

;; Convenience: all pending POs.
(defn pending-pos [(pos : Any)] : Any
  (filterv (fn [po] (= (purchaseorder-status po) "pending")) pos))

;; All approved POs.
(defn approved-pos [(pos : Any)] : Any
  (filterv (fn [po] (= (purchaseorder-status po) "approved")) pos))

;; All completed POs.
(defn completed-pos [(pos : Any)] : Any
  (filterv (fn [po] (= (purchaseorder-status po) "completed")) pos))

;; All cancelled POs.
(defn cancelled-pos [(pos : Any)] : Any
  (filterv (fn [po] (= (purchaseorder-status po) "cancelled")) pos))

;; POs created within a time range (inclusive on both ends).
(defn pos-in-period [(pos : Any) (start : Long) (end : Long)] : Any
  (filterv (fn [po] (and (>= (purchaseorder-created-at po) start)
                         (<= (purchaseorder-created-at po) end)))
           pos))

;; Sort POs by total descending (largest first).
(defn sort-pos-by-total [(pos : Any)] : Any
  (reverse (sort-by purchaseorder-total pos)))

;; Sort POs by created-at ascending (oldest first).
(defn sort-pos-by-date [(pos : Any)] : Any
  (sort-by purchaseorder-created-at pos))

;; ===========================================================================
;; Purchase order state transitions
;; ===========================================================================

;; Approve a PO — only valid when status is "pending".
(defn approve-po [(po : PurchaseOrder)] : PurchaseOrder
  (if (= (purchaseorder-status po) "pending")
      (->PurchaseOrder (purchaseorder-id po)
                       (purchaseorder-supplier-id po)
                       "approved"
                       (purchaseorder-created-at po)
                       (purchaseorder-expected-at po)
                       (purchaseorder-total po))
      po))

;; Mark a PO completed (any current status).
(defn complete-po [(po : PurchaseOrder)] : PurchaseOrder
  (->PurchaseOrder (purchaseorder-id po)
                   (purchaseorder-supplier-id po)
                   "completed"
                   (purchaseorder-created-at po)
                   (purchaseorder-expected-at po)
                   (purchaseorder-total po)))

;; Cancel a PO — only valid when status is "pending".
(defn cancel-po [(po : PurchaseOrder)] : PurchaseOrder
  (if (= (purchaseorder-status po) "pending")
      (->PurchaseOrder (purchaseorder-id po)
                       (purchaseorder-supplier-id po)
                       "cancelled"
                       (purchaseorder-created-at po)
                       (purchaseorder-expected-at po)
                       (purchaseorder-total po))
      po))

;; Check whether a PO is in an open (actionable) state.
(defn po-open? [(po : PurchaseOrder)] : Boolean
  (or (= (purchaseorder-status po) "pending")
      (= (purchaseorder-status po) "approved")))

;; Check whether a PO is in a terminal state.
(defn po-closed? [(po : PurchaseOrder)] : Boolean
  (or (= (purchaseorder-status po) "completed")
      (= (purchaseorder-status po) "cancelled")))

;; Days between creation and expected delivery.
(defn po-expected-lead-days [(po : PurchaseOrder)] : Long
  (let [elapsed (- (purchaseorder-expected-at po)
                   (purchaseorder-created-at po))]
    (quot elapsed 86400)))

;; ===========================================================================
;; Purchase order validation
;; ===========================================================================

;; A PO is valid when it has a positive id, a positive supplier-id,
;; a non-empty status, and a non-negative total.
(defn valid-po? [(po : PurchaseOrder)] : Boolean
  (and (> (purchaseorder-id po) 0)
       (> (purchaseorder-supplier-id po) 0)
       (not= (purchaseorder-status po) "")
       (>= (purchaseorder-total po) 0)))

;; A PO line is valid when product-id > 0, quantity > 0, unit-cost >= 0.
(defn valid-poline? [(line : POLine)] : Boolean
  (and (> (poline-product-id line) 0)
       (> (poline-quantity line) 0)
       (>= (poline-unit-cost line) 0)))

;; Filter a set of PO lines down to only valid ones.
(defn valid-lines [(lines : Any)] : Any
  (filterv valid-poline? lines))

;; Check whether every line in a set is valid.
(defn all-lines-valid? [(lines : Any)] : Boolean
  (every? valid-poline? lines))

;; ===========================================================================
;; Goods receipt operations
;; ===========================================================================

;; Create a goods receipt — line-count is derived from lines matching po-id.
(defn create-goods-receipt [(id : Long) (po-id : Long)
                            (warehouse-id : Long) (received-at : Long)
                            (lines : Any)] : GoodsReceipt
  (let [lc (count (filterv (fn [line] (= (poline-po-id line) po-id))
                           lines))]
    (->GoodsReceipt id po-id warehouse-id received-at lc)))

;; All receipts for a given PO.
(defn receipts-for-po [(receipts : Any) (po-id : Long)] : Any
  (filterv (fn [r] (= (goodsreceipt-po-id r) po-id)) receipts))

;; All receipts at a given warehouse.
(defn receipts-for-warehouse [(receipts : Any) (warehouse-id : Long)] : Any
  (filterv (fn [r] (= (goodsreceipt-warehouse-id r) warehouse-id)) receipts))

;; Find a receipt by its id.
(defn find-receipt-by-id [(receipts : Any) (id : Long)] : Any
  (first (filterv (fn [r] (= (goodsreceipt-id r) id)) receipts)))

;; Receipts that arrived within a time window.
(defn receipts-in-period [(receipts : Any) (start : Long)
                          (end : Long)] : Any
  (filterv (fn [r] (and (>= (goodsreceipt-received-at r) start)
                        (<= (goodsreceipt-received-at r) end)))
           receipts))

;; Total line-count across all receipts for a PO.
(defn total-lines-received-for-po [(receipts : Any) (po-id : Long)] : Long
  (reduce (fn [acc r] (+ acc (goodsreceipt-line-count r)))
          0
          (receipts-for-po receipts po-id)))

;; Whether a PO has at least one goods receipt.
(defn po-has-receipt? [(receipts : Any) (po-id : Long)] : Boolean
  (not (empty? (receipts-for-po receipts po-id))))

;; Count of distinct POs that have been received at a warehouse.
(defn warehouse-receipt-count [(receipts : Any) (warehouse-id : Long)] : Long
  (count (receipts-for-warehouse receipts warehouse-id)))

;; ===========================================================================
;; Analysis: supplier metrics
;; ===========================================================================

;; Sum poline-total for all lines belonging to a supplier's POs.
(defn supplier-total-ordered [(pos : Any) (lines : Any)
                              (supplier-id : Long)] : Long
  (let [supplier-pos (pos-for-supplier pos supplier-id)
        supplier-po-ids (mapv (fn [po] (purchaseorder-id po)) supplier-pos)
        matching-lines (filterv
                         (fn [line]
                           (some (fn [pid] (= pid (poline-po-id line)))
                                 supplier-po-ids))
                         lines)]
    (reduce (fn [acc line] (+ acc (poline-quantity line)))
            0 matching-lines)))

;; Number of POs placed with a supplier.
(defn supplier-order-count [(pos : Any) (supplier-id : Long)] : Long
  (count (pos-for-supplier pos supplier-id)))

;; Average PO value for a supplier (total / count).
(defn supplier-avg-order-value [(pos : Any) (supplier-id : Long)] : Long
  (let [spos (pos-for-supplier pos supplier-id)
        cnt (count spos)]
    (if (= cnt 0) 0
        (let [total (reduce (fn [acc po]
                              (+ acc (purchaseorder-total po)))
                            0 spos)]
          (quot total cnt)))))

;; Number of completed POs for a supplier.
(defn supplier-completed-count [(pos : Any) (supplier-id : Long)] : Long
  (count (filterv (fn [po] (= (purchaseorder-status po) "completed"))
                  (pos-for-supplier pos supplier-id))))

;; Completion rate (0-100) for a supplier's POs.
(defn supplier-completion-rate [(pos : Any) (supplier-id : Long)] : Long
  (let [spos (pos-for-supplier pos supplier-id)
        total (count spos)
        completed (count (filterv (fn [po]
                                    (= (purchaseorder-status po) "completed"))
                                  spos))]
    (if (= total 0) 0 (quot (* completed 100) total))))

;; Cancellation rate (0-100) for a supplier.
(defn supplier-cancellation-rate [(pos : Any) (supplier-id : Long)] : Long
  (let [spos (pos-for-supplier pos supplier-id)
        total (count spos)
        cancelled (count (filterv (fn [po]
                                    (= (purchaseorder-status po) "cancelled"))
                                  spos))]
    (if (= total 0) 0 (quot (* cancelled 100) total))))

;; Total spend on completed POs for a supplier.
(defn supplier-completed-spend [(pos : Any) (supplier-id : Long)] : Long
  (reduce (fn [acc po] (+ acc (purchaseorder-total po)))
          0
          (filterv (fn [po] (= (purchaseorder-status po) "completed"))
                   (pos-for-supplier pos supplier-id))))

;; ===========================================================================
;; Analysis: overdue POs
;; ===========================================================================

;; Open POs whose expected-at is before `now`.
(defn overdue-pos [(pos : Any) (now : Long)] : Any
  (filterv (fn [po]
             (and (po-open? po)
                  (< (purchaseorder-expected-at po) now)))
           pos))

;; Count of overdue POs.
(defn overdue-count [(pos : Any) (now : Long)] : Long
  (count (overdue-pos pos now)))

;; Total value of overdue POs.
(defn overdue-total [(pos : Any) (now : Long)] : Long
  (reduce (fn [acc po] (+ acc (purchaseorder-total po)))
          0
          (overdue-pos pos now)))

;; Days overdue for a single PO (0 if not overdue).
(defn po-days-overdue [(po : PurchaseOrder) (now : Long)] : Long
  (let [diff (- now (purchaseorder-expected-at po))]
    (if (> diff 0) (quot diff 86400) 0)))

;; ===========================================================================
;; Analysis: auto-reorder
;; ===========================================================================

;; For each item that inv/reorder-needed identifies, create a POLine with
;; placeholder po-id = 0, the product's reorder quantity, and the product's
;; catalog unit cost.
(defn auto-reorder-lines [(levels : Any) (products : Any)] : Any
  (let [needed (inv/reorder-needed)]
    (mapv (fn [sl]
            (let [prod-id (inv/stocklevel-product-id sl)
                  qty (inv/reorder-quantity sl)
                  prod (cat/find-product-by-id products prod-id)
                  cost (if (nil? prod) 0 (cat/product-unit-cost prod))]
              (->POLine 0 prod-id qty cost)))
          needed)))

;; Total estimated cost of all auto-reorder lines.
(defn auto-reorder-cost [(levels : Any) (products : Any)] : Long
  (po-total-from-lines (auto-reorder-lines levels products)))

;; Count of distinct products that need reorder.
(defn auto-reorder-product-count [(levels : Any)] : Long
  (count (inv/reorder-needed levels)))

;; ===========================================================================
;; Analysis: procurement spend
;; ===========================================================================

;; Sum of totals for all completed POs.
(defn total-procurement-spend [(pos : Any)] : Long
  (reduce (fn [acc po] (+ acc (purchaseorder-total po)))
          0
          (filterv (fn [po] (= (purchaseorder-status po) "completed"))
                   pos)))

;; Sum of totals for all open (pending + approved) POs.
(defn open-procurement-value [(pos : Any)] : Long
  (reduce (fn [acc po] (+ acc (purchaseorder-total po)))
          0
          (filterv po-open? pos)))

;; Sum of totals for all POs regardless of status.
(defn gross-procurement-value [(pos : Any)] : Long
  (reduce (fn [acc po] (+ acc (purchaseorder-total po))) 0 pos))

;; Average PO value across all POs.
(defn avg-po-value [(pos : Any)] : Long
  (let [cnt (count pos)]
    (if (= cnt 0) 0
        (quot (gross-procurement-value pos) cnt))))

;; Procurement spend within a date range (by created-at, completed POs only).
(defn period-procurement-spend [(pos : Any) (start : Long)
                                (end : Long)] : Long
  (reduce (fn [acc po] (+ acc (purchaseorder-total po)))
          0
          (filterv (fn [po]
                     (and (= (purchaseorder-status po) "completed")
                          (>= (purchaseorder-created-at po) start)
                          (<= (purchaseorder-created-at po) end)))
                   pos)))

;; ===========================================================================
;; Analysis: lead time
;; ===========================================================================

;; Average actual lead time in days for completed POs that have receipts.
;; Lead time = (received-at - created-at) / 86400.
(defn avg-lead-time-actual [(pos : Any) (receipts : Any)] : Long
  (let [completed (filterv (fn [po]
                             (= (purchaseorder-status po) "completed"))
                           pos)
        with-receipt (filterv
                       (fn [po]
                         (not (empty? (receipts-for-po
                                        receipts
                                        (purchaseorder-id po)))))
                       completed)]
    (if (empty? with-receipt) 0
        (let [total-days
              (reduce
                (fn [acc po]
                  (let [po-receipts (receipts-for-po
                                      receipts (purchaseorder-id po))
                        first-receipt (first po-receipts)
                        elapsed (- (goodsreceipt-received-at first-receipt)
                                   (purchaseorder-created-at po))
                        days (quot elapsed 86400)]
                    (+ acc days)))
                0 with-receipt)]
          (quot total-days (count with-receipt))))))

;; Actual lead time for a single completed PO (days).  Returns 0 when no
;; receipt exists.
(defn po-actual-lead-days [(po : PurchaseOrder) (receipts : Any)] : Long
  (let [po-receipts (receipts-for-po receipts (purchaseorder-id po))]
    (if (empty? po-receipts) 0
        (let [first-receipt (first po-receipts)
              elapsed (- (goodsreceipt-received-at first-receipt)
                         (purchaseorder-created-at po))]
          (quot elapsed 86400)))))

;; Variance between expected and actual lead time for a PO.
;; Positive = arrived late, negative = arrived early.
(defn po-lead-variance-days [(po : PurchaseOrder) (receipts : Any)] : Long
  (let [actual (po-actual-lead-days po receipts)
        expected (po-expected-lead-days po)]
    (- actual expected)))

;; Max actual lead time across completed POs with receipts.
(defn max-lead-time-actual [(pos : Any) (receipts : Any)] : Long
  (let [completed (filterv (fn [po]
                             (= (purchaseorder-status po) "completed"))
                           pos)
        with-receipt (filterv
                       (fn [po]
                         (not (empty? (receipts-for-po
                                        receipts
                                        (purchaseorder-id po)))))
                       completed)]
    (if (empty? with-receipt) 0
        (reduce (fn [mx po]
                  (let [days (po-actual-lead-days po receipts)]
                    (if (> days mx) days mx)))
                0 with-receipt))))

;; ===========================================================================
;; Formatting / summaries
;; ===========================================================================

;; Human-readable one-line summary of a purchase order.
(defn po-summary [(po : PurchaseOrder)] : String
  (str "PO#" (purchaseorder-id po)
       " supplier:" (purchaseorder-supplier-id po)
       " status:" (purchaseorder-status po)
       " total:" (purchaseorder-total po)))

;; Human-readable one-line summary of a PO line.
(defn poline-summary [(line : POLine)] : String
  (str "POLine po:" (poline-po-id line)
       " product:" (poline-product-id line)
       " qty:" (poline-quantity line)
       " @" (poline-unit-cost line)
       " = " (poline-total line)))

;; Human-readable one-line summary of a goods receipt.
(defn receipt-summary [(r : GoodsReceipt)] : String
  (str "GR#" (goodsreceipt-id r)
       " po:" (goodsreceipt-po-id r)
       " wh:" (goodsreceipt-warehouse-id r)
       " lines:" (goodsreceipt-line-count r)))

;; PO detail including product names from catalog.
(defn po-detail [(po : PurchaseOrder) (lines : Any)
                 (products : Any)] : String
  (let [po-lines (lines-for-po lines (purchaseorder-id po))
        line-strs (mapv (fn [line]
                          (let [prod (cat/find-product-by-id
                                       products
                                       (poline-product-id line))
                                pname (if (nil? prod) "unknown"
                                          (cat/product-name prod))]
                            (str "  " pname
                                 " qty:" (poline-quantity line)
                                 " @" (poline-unit-cost line))))
                        po-lines)]
    (str (po-summary po) "\n"
         (reduce (fn [acc s] (str acc s "\n")) "" line-strs))))

;; ===========================================================================
;; Cross-module: PO lines enriched with product info
;; ===========================================================================

;; Attach product name and current stock quantity to each PO line.
(defn enrich-lines [(lines : Any) (products : Any)
                    (levels : Any)] : Any
  (mapv (fn [line]
          (let [prod-id (poline-product-id line)
                prod (cat/find-product-by-id products prod-id)
                pname (if (nil? prod) "unknown" (cat/product-name prod))
                stock (inv/total-stock-for-product levels prod-id)]
            {:po-id (poline-po-id line)
             :product-id prod-id
             :product-name pname
             :quantity (poline-quantity line)
             :unit-cost (poline-unit-cost line)
             :line-total (poline-total line)
             :current-stock stock}))
        lines))

;; Products referenced in PO lines that don't exist in catalog.
(defn orphan-line-product-ids [(lines : Any) (products : Any)] : Any
  (filterv (fn [pid] (nil? (cat/find-product-by-id products pid)))
           (unique-products-in-lines lines)))

;; ===========================================================================
;; Aggregate statistics
;; ===========================================================================

;; Count POs grouped by status.  Returns a map.
(defn po-count-by-status [(pos : Any)] : Any
  {:pending (count (pending-pos pos))
   :approved (count (approved-pos pos))
   :completed (count (completed-pos pos))
   :cancelled (count (cancelled-pos pos))})

;; Total number of PO lines across all POs in a collection of lines.
(defn total-line-count [(lines : Any)] : Long
  (count lines))

;; Total units ordered across all lines.
(defn total-units-ordered [(lines : Any)] : Long
  (reduce (fn [acc line] (+ acc (poline-quantity line))) 0 lines))

;; Average line value across all lines.
(defn avg-line-value [(lines : Any)] : Long
  (let [cnt (count lines)]
    (if (= cnt 0) 0
        (quot (po-total-from-lines lines) cnt))))

;; Average quantity per line.
(defn avg-line-quantity [(lines : Any)] : Long
  (let [cnt (count lines)]
    (if (= cnt 0) 0
        (quot (total-units-ordered lines) cnt))))

;; Largest single PO by total.
(defn largest-po [(pos : Any)] : Any
  (if (empty? pos) nil
      (reduce (fn [best po]
                (if (> (purchaseorder-total po)
                       (purchaseorder-total best))
                    po best))
              (first pos) (rest pos))))

;; Smallest non-cancelled PO by total.
(defn smallest-active-po [(pos : Any)] : Any
  (let [active (filterv (fn [po] (not= (purchaseorder-status po) "cancelled"))
                        pos)]
    (if (empty? active) nil
        (reduce (fn [best po]
                  (if (< (purchaseorder-total po)
                         (purchaseorder-total best))
                      po best))
                (first active) (rest active)))))

;; ===========================================================================
;; Cost analysis helpers
;; ===========================================================================

;; Compare current catalog unit-cost to the average PO unit-cost for a product.
;; Positive result means PO cost is higher than catalog cost.
(defn cost-variance [(lines : Any) (products : Any)
                     (product-id : Long)] : Long
  (let [avg-po-cost (avg-unit-cost-for-product lines product-id)
        prod (cat/find-product-by-id products product-id)
        cat-cost (if (nil? prod) 0 (cat/product-unit-cost prod))]
    (- avg-po-cost cat-cost)))

;; Products where PO cost exceeds catalog cost (potential price inflation).
(defn products-over-catalog-cost [(lines : Any) (products : Any)] : Any
  (let [pids (unique-products-in-lines lines)]
    (filterv (fn [pid]
               (let [variance (cost-variance lines products pid)]
                 (> variance 0)))
             pids)))

;; Total value of all goods receipts at a warehouse (sum line-count * avg line
;; value, approximate).  Uses PO total / PO line-count as proxy per line.
(defn warehouse-received-value [(pos : Any) (receipts : Any) (lines : Any)
                                (warehouse-id : Long)] : Long
  (let [wh-receipts (receipts-for-warehouse receipts warehouse-id)]
    (reduce (fn [acc r]
              (let [po (find-po-by-id pos (goodsreceipt-po-id r))
                    po-total (if (nil? po) 0 (purchaseorder-total po))]
                (+ acc po-total)))
            0 wh-receipts)))

;; ===========================================================================
;; Dashboard / KPI summary
;; ===========================================================================

;; Procurement KPI dashboard — returns a map of key metrics.
(defn procurement-dashboard [(pos : Any) (lines : Any) (receipts : Any)
                             (now : Long)] : Any
  (let [total-spend (total-procurement-spend pos)
        open-value (open-procurement-value pos)
        overdue-cnt (overdue-count pos now)
        overdue-val (overdue-total pos now)
        avg-lead (avg-lead-time-actual pos receipts)
        po-cnt (count pos)
        line-cnt (total-line-count lines)
        units (total-units-ordered lines)]
    {:total-spend total-spend
     :open-value open-value
     :overdue-count overdue-cnt
     :overdue-value overdue-val
     :avg-lead-time-days avg-lead
     :po-count po-cnt
     :line-count line-cnt
     :total-units units}))
