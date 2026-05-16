#lang beagle

(ns promotions)

(require catalog :as cat)
(require customers :as cust)
(require orders :as ord)

;; ===========================================================================
;; Records
;; ===========================================================================

(defrecord Campaign [(id : Long) (name : String) (start-date : Long)
                     (end-date : Long) (status : String)])

(defrecord Coupon [(id : Long) (campaign-id : Long) (code : String)
                   (discount-type : String) (discount-value : Long)
                   (min-order : Long) (max-uses : Long)
                   (current-uses : Long)])

(defrecord PromotionRule [(id : Long) (campaign-id : Long)
                          (min-tier : String) (min-order-value : Long)
                          (category-id : Long)])

;; ===========================================================================
;; Campaign operations
;; ===========================================================================

;; Find a campaign by its unique id. Returns nil when not found.
(defn find-campaign-by-id [(campaigns : Any) (id : Long)] : Any
  (first (filterv (fn [c] (= (campaign-id c) id)) campaigns)))

;; A campaign is active when its status is "active" and the current
;; timestamp falls within the start/end window.
(defn campaign-active? [(campaign : Campaign) (now : Long)] : Boolean
  (and (= (campaign-status campaign) "active")
       (<= (campaign-start-date campaign) now)
       (<= now (campaign-end-date campaign))))

;; Return all campaigns that are active at timestamp `now`.
(defn active-campaigns [(campaigns : Any) (now : Long)] : Any
  (filterv (fn [c] (campaign-active? c now)) campaigns))

;; Set a campaign's status to "active".
(defn activate-campaign [(campaign : Campaign)] : Campaign
  (->Campaign (campaign-id campaign) (campaign-name campaign)
              (campaign-start-date campaign) (campaign-end-date campaign)
              "active"))

;; Set a campaign's status to "inactive".
(defn deactivate-campaign [(campaign : Campaign)] : Campaign
  (->Campaign (campaign-id campaign) (campaign-name campaign)
              (campaign-start-date campaign) (campaign-end-date campaign)
              "inactive"))

;; Filter campaigns by an arbitrary status string.
(defn campaigns-by-status [(campaigns : Any) (status : String)] : Any
  (filterv (fn [c] (= (campaign-status c) status)) campaigns))

;; Duration of a campaign expressed in whole days.
(defn campaign-duration-days [(campaign : Campaign)] : Long
  (quot (- (campaign-end-date campaign) (campaign-start-date campaign))
        86400))

;; ===========================================================================
;; Coupon operations
;; ===========================================================================

;; Look up a coupon by its human-readable code.
(defn find-coupon-by-code [(coupons : Any) (code : String)] : Any
  (first (filterv (fn [c] (= (coupon-code c) code)) coupons)))

;; Look up a coupon by numeric id.
(defn find-coupon-by-id [(coupons : Any) (id : Long)] : Any
  (first (filterv (fn [c] (= (coupon-id c) id)) coupons)))

;; All coupons that belong to a given campaign.
(defn coupons-for-campaign [(coupons : Any) (cid : Long)] : Any
  (filterv (fn [c] (= (coupon-campaign-id c) cid)) coupons))

;; A coupon is valid when its usage count has not reached its maximum.
(defn coupon-valid? [(coupon : Coupon)] : Boolean
  (< (coupon-current-uses coupon) (coupon-max-uses coupon)))

;; Consume one use of a coupon, incrementing current-uses.
;; Returns the coupon unchanged if already exhausted.
(defn use-coupon [(coupon : Coupon)] : Coupon
  (if (coupon-valid? coupon)
      (->Coupon (coupon-id coupon) (coupon-campaign-id coupon)
                (coupon-code coupon) (coupon-discount-type coupon)
                (coupon-discount-value coupon) (coupon-min-order coupon)
                (coupon-max-uses coupon)
                (+ (coupon-current-uses coupon) 1))
      coupon))

;; Percentage of max-uses that have been consumed (0-100).
(defn coupon-usage-pct [(coupon : Coupon)] : Long
  (if (= (coupon-max-uses coupon) 0)
      0
      (quot (* (coupon-current-uses coupon) 100)
            (coupon-max-uses coupon))))

;; Calculate the monetary discount a coupon provides for a given order
;; total.  "percentage" coupons use (order-total * value / 100);
;; "fixed" coupons use the raw discount-value.  The result is capped
;; at order-total so the discount cannot exceed the order value.
(defn coupon-discount-amount [(coupon : Coupon) (order-total : Long)] : Long
  (let [raw (if (= (coupon-discount-type coupon) "percentage")
                (quot (* order-total (coupon-discount-value coupon)) 100)
                (coupon-discount-value coupon))]
    (if (> raw order-total) order-total raw)))

;; Among all *valid* coupons, find the one that yields the largest
;; discount for the given order total.  Returns nil when no valid
;; coupon exists.
(defn best-coupon [(coupons : Any) (order-total : Long)] : Any
  (let [valid (filterv coupon-valid? coupons)]
    (if (empty? valid)
        nil
        (reduce (fn [best c]
                  (if (> (coupon-discount-amount c order-total)
                         (coupon-discount-amount best order-total))
                      c
                      best))
                (first valid) (rest valid)))))

;; ===========================================================================
;; Promotion-rule operations
;; ===========================================================================

;; All rules that belong to a given campaign.
(defn find-rules-for-campaign [(rules : Any) (cid : Long)] : Any
  (filterv (fn [r] (= (promotionrule-campaign-id r) cid)) rules))

;; Tier hierarchy check.
;; gold (3) > silver (2) > bronze (1) > "" (any, 0).
;; A customer-tier qualifies when its rank >= min-tier rank.
;; When min-tier is "" any tier qualifies.
(defn tier-qualifies? [(customer-tier : String) (min-tier : String)] : Boolean
  (if (= min-tier "")
      true
      (let [tier-val (cond
                       [(= customer-tier "gold") 3]
                       [(= customer-tier "silver") 2]
                       [(= customer-tier "bronze") 1]
                       [true 0])
            min-val (cond
                      [(= min-tier "gold") 3]
                      [(= min-tier "silver") 2]
                      [(= min-tier "bronze") 1]
                      [true 0])]
        (>= tier-val min-val))))

;; Does the customer's tier satisfy the rule's min-tier?
(defn customer-eligible? [(rule : PromotionRule) (customer : Any)] : Boolean
  (tier-qualifies? (cust/customer-tier customer)
                   (promotionrule-min-tier rule)))

;; Does the order total meet the rule's minimum order value?
(defn order-eligible? [(rule : PromotionRule) (order : Any)] : Boolean
  (>= (ord/order-total order) (promotionrule-min-order-value rule)))

;; Both tier and order-value constraints are met.
(defn rule-applies? [(rule : PromotionRule) (customer : Any) (order : Any)] : Boolean
  (and (customer-eligible? rule customer)
       (order-eligible? rule order)))

;; ===========================================================================
;; Analytics — discount and usage metrics
;; ===========================================================================

;; Sum of ord/order-discount across all orders.
(defn total-discount-given [(coupons : Any) (orders : Any)] : Long
  (reduce (fn [acc o] (+ acc (ord/order-discount o))) 0 orders))

;; Number of coupons that belong to a campaign.
(defn campaign-coupon-count [(coupons : Any) (cid : Long)] : Long
  (count (coupons-for-campaign coupons cid)))

;; Sum of current-uses for all coupons in a campaign.
(defn campaign-total-uses [(coupons : Any) (cid : Long)] : Long
  (reduce (fn [acc c] (+ acc (coupon-current-uses c)))
          0
          (coupons-for-campaign coupons cid)))

;; Approximate total discount a campaign's coupons have generated.
;; Uses a reference order-total of 10000 (cents) multiplied by each
;; coupon's uses.
(defn campaign-total-discount [(coupons : Any) (cid : Long) (order-total-fn : Any)] : Long
  (let [camp-coupons (coupons-for-campaign coupons cid)]
    (reduce (fn [acc c]
              (+ acc (* (coupon-current-uses c)
                        (coupon-discount-amount c 10000))))
            0
            camp-coupons)))

;; ===========================================================================
;; Extended coupon helpers
;; ===========================================================================

;; Remaining uses before a coupon is exhausted.
(defn coupon-remaining-uses [(coupon : Coupon)] : Long
  (let [rem (- (coupon-max-uses coupon) (coupon-current-uses coupon))]
    (if (< rem 0) 0 rem)))

;; Is the coupon fully exhausted?
(defn coupon-exhausted? [(coupon : Coupon)] : Boolean
  (>= (coupon-current-uses coupon) (coupon-max-uses coupon)))

;; Coupons whose current-uses have reached max-uses.
(defn exhausted-coupons [(coupons : Any)] : Any
  (filterv (fn [c] (coupon-exhausted? c)) coupons))

;; Coupons that still have uses remaining.
(defn valid-coupons [(coupons : Any)] : Any
  (filterv coupon-valid? coupons))

;; Does this coupon's min-order threshold accept the given order total?
(defn coupon-applicable? [(coupon : Coupon) (order-total : Long)] : Boolean
  (and (coupon-valid? coupon)
       (>= order-total (coupon-min-order coupon))))

;; Filter coupons applicable to a given order total.
(defn applicable-coupons [(coupons : Any) (order-total : Long)] : Any
  (filterv (fn [c] (coupon-applicable? c order-total)) coupons))

;; Reset a coupon's usage counter to zero, returning a fresh copy.
(defn reset-coupon-uses [(coupon : Coupon)] : Coupon
  (->Coupon (coupon-id coupon) (coupon-campaign-id coupon)
            (coupon-code coupon) (coupon-discount-type coupon)
            (coupon-discount-value coupon) (coupon-min-order coupon)
            (coupon-max-uses coupon) 0))

;; Percentage coupons only.
(defn percentage-coupons [(coupons : Any)] : Any
  (filterv (fn [c] (= (coupon-discount-type c) "percentage")) coupons))

;; Fixed coupons only.
(defn fixed-coupons [(coupons : Any)] : Any
  (filterv (fn [c] (= (coupon-discount-type c) "fixed")) coupons))

;; ===========================================================================
;; Extended campaign helpers
;; ===========================================================================

;; Has the campaign not yet started?
(defn campaign-upcoming? [(campaign : Campaign) (now : Long)] : Boolean
  (and (= (campaign-status campaign) "active")
       (> (campaign-start-date campaign) now)))

;; Has the campaign passed its end date?
(defn campaign-expired? [(campaign : Campaign) (now : Long)] : Boolean
  (< (campaign-end-date campaign) now))

;; Campaigns that haven't started yet.
(defn upcoming-campaigns [(campaigns : Any) (now : Long)] : Any
  (filterv (fn [c] (campaign-upcoming? c now)) campaigns))

;; Campaigns that have expired.
(defn expired-campaigns [(campaigns : Any) (now : Long)] : Any
  (filterv (fn [c] (campaign-expired? c now)) campaigns))

;; How many days remain until the campaign ends, measured from `now`.
;; Returns 0 if already past end-date.
(defn campaign-days-remaining [(campaign : Campaign) (now : Long)] : Long
  (let [diff (- (campaign-end-date campaign) now)]
    (if (<= diff 0) 0 (quot diff 86400))))

;; How many days have elapsed since the campaign started.
;; Returns 0 if not yet started.
(defn campaign-days-elapsed [(campaign : Campaign) (now : Long)] : Long
  (let [diff (- now (campaign-start-date campaign))]
    (if (<= diff 0) 0 (quot diff 86400))))

;; Percentage of the campaign duration that has elapsed (0-100).
(defn campaign-progress-pct [(campaign : Campaign) (now : Long)] : Long
  (let [total (- (campaign-end-date campaign) (campaign-start-date campaign))
        elapsed (- now (campaign-start-date campaign))]
    (cond
      [(<= total 0) 100]
      [(<= elapsed 0) 0]
      [(>= elapsed total) 100]
      [true (quot (* elapsed 100) total)])))

;; Sort campaigns by start-date ascending.
(defn sort-campaigns-by-start [(campaigns : Any)] : Any
  (sort-by campaign-start-date campaigns))

;; Sort campaigns by end-date ascending.
(defn sort-campaigns-by-end [(campaigns : Any)] : Any
  (sort-by campaign-end-date campaigns))

;; Return total number of campaigns.
(defn total-campaign-count [(campaigns : Any)] : Long
  (count campaigns))

;; Count campaigns by a given status.
(defn campaign-count-by-status [(campaigns : Any) (status : String)] : Long
  (count (campaigns-by-status campaigns status)))

;; ===========================================================================
;; Extended rule helpers
;; ===========================================================================

;; All rules that target a specific product category.
(defn rules-for-category [(rules : Any) (cat-id : Long)] : Any
  (filterv (fn [r] (= (promotionrule-category-id r) cat-id)) rules))

;; Rules that have no category restriction (category-id == 0).
(defn universal-rules [(rules : Any)] : Any
  (filterv (fn [r] (= (promotionrule-category-id r) 0)) rules))

;; Rules that do restrict by category.
(defn category-specific-rules [(rules : Any)] : Any
  (filterv (fn [r] (not= (promotionrule-category-id r) 0)) rules))

;; Does any rule in the set apply to this customer + order pair?
(defn any-rule-applies? [(rules : Any) (customer : Any) (order : Any)] : Boolean
  (some (fn [r] (rule-applies? r customer order)) rules))

;; Collect all rules that apply to a customer + order pair.
(defn matching-rules [(rules : Any) (customer : Any) (order : Any)] : Any
  (filterv (fn [r] (rule-applies? r customer order)) rules))

;; Count of rules for a campaign.
(defn campaign-rule-count [(rules : Any) (cid : Long)] : Long
  (count (find-rules-for-campaign rules cid)))

;; ===========================================================================
;; Cross-module helpers — customer qualification
;; ===========================================================================

;; Given a customer and an order, find all active campaigns at `now`
;; where at least one rule applies.
(defn eligible-campaigns [(campaigns : Any) (rules : Any)
                          (customer : Any) (order : Any) (now : Long)] : Any
  (let [active (active-campaigns campaigns now)]
    (filterv (fn [camp]
               (let [camp-rules (find-rules-for-campaign rules (campaign-id camp))]
                 (any-rule-applies? camp-rules customer order)))
             active)))

;; Total number of campaigns a customer qualifies for.
(defn eligible-campaign-count [(campaigns : Any) (rules : Any)
                               (customer : Any) (order : Any)
                               (now : Long)] : Long
  (count (eligible-campaigns campaigns rules customer order now)))

;; Best available coupon for a customer's order — filters by campaign
;; eligibility, coupon applicability, then picks the highest discount.
(defn best-eligible-coupon [(campaigns : Any) (coupons : Any) (rules : Any)
                            (customer : Any) (order : Any) (now : Long)] : Any
  (let [elig-camps (eligible-campaigns campaigns rules customer order now)
        camp-ids (mapv campaign-id elig-camps)
        camp-coupons (filterv (fn [c]
                                (some (fn [cid] (= cid (coupon-campaign-id c)))
                                      camp-ids))
                              coupons)
        order-total (ord/order-total order)
        usable (filterv (fn [c] (coupon-applicable? c order-total))
                        camp-coupons)]
    (if (empty? usable)
        nil
        (reduce (fn [best c]
                  (if (> (coupon-discount-amount c order-total)
                         (coupon-discount-amount best order-total))
                      c
                      best))
                (first usable) (rest usable)))))

;; ===========================================================================
;; Validation
;; ===========================================================================

;; A campaign is structurally valid when it has a positive id, a
;; non-empty name, and start-date < end-date.
(defn valid-campaign? [(campaign : Campaign)] : Boolean
  (and (> (campaign-id campaign) 0)
       (not= (campaign-name campaign) "")
       (< (campaign-start-date campaign) (campaign-end-date campaign))))

;; A coupon is structurally valid when it has positive id, a non-empty
;; code, and non-negative numeric fields.
(defn valid-coupon? [(coupon : Coupon)] : Boolean
  (and (> (coupon-id coupon) 0)
       (not= (coupon-code coupon) "")
       (> (coupon-discount-value coupon) 0)
       (>= (coupon-min-order coupon) 0)
       (> (coupon-max-uses coupon) 0)
       (>= (coupon-current-uses coupon) 0)))

;; A rule is valid when it has a positive id and non-negative
;; min-order-value.
(defn valid-rule? [(rule : PromotionRule)] : Boolean
  (and (> (promotionrule-id rule) 0)
       (>= (promotionrule-min-order-value rule) 0)
       (>= (promotionrule-category-id rule) 0)))

;; ===========================================================================
;; Formatting
;; ===========================================================================

;; Human-readable campaign summary.
(defn campaign-summary [(campaign : Campaign)] : String
  (str (campaign-name campaign) " [" (campaign-status campaign) "]"
       " (" (campaign-start-date campaign) " - "
       (campaign-end-date campaign) ")"))

;; Human-readable campaign detail with duration.
(defn campaign-detail [(campaign : Campaign)] : String
  (str "Campaign #" (campaign-id campaign)
       " | " (campaign-name campaign)
       " | Status: " (campaign-status campaign)
       " | Duration: " (campaign-duration-days campaign) " days"))

;; Human-readable coupon summary.
(defn coupon-summary [(coupon : Coupon)] : String
  (str (coupon-code coupon) " ("
       (coupon-discount-type coupon) " "
       (coupon-discount-value coupon) ")"
       " uses: " (coupon-current-uses coupon) "/" (coupon-max-uses coupon)))

;; Human-readable coupon detail with min-order and campaign.
(defn coupon-detail [(coupon : Coupon)] : String
  (str "Coupon #" (coupon-id coupon)
       " | Code: " (coupon-code coupon)
       " | Type: " (coupon-discount-type coupon)
       " | Value: " (coupon-discount-value coupon)
       " | Min-order: " (coupon-min-order coupon)
       " | Uses: " (coupon-current-uses coupon) "/" (coupon-max-uses coupon)
       " | Campaign: " (coupon-campaign-id coupon)))

;; Human-readable rule summary.
(defn rule-summary [(rule : PromotionRule)] : String
  (str "Rule #" (promotionrule-id rule)
       " | Campaign: " (promotionrule-campaign-id rule)
       " | Min-tier: " (if (= (promotionrule-min-tier rule) "")
                            "any" (promotionrule-min-tier rule))
       " | Min-order: " (promotionrule-min-order-value rule)
       " | Category: " (if (= (promotionrule-category-id rule) 0)
                            "any" (str (promotionrule-category-id rule)))))

;; ===========================================================================
;; Sorting
;; ===========================================================================

;; Sort coupons by discount-value descending (largest first).
(defn sort-coupons-by-value [(coupons : Any)] : Any
  (reverse (sort-by coupon-discount-value coupons)))

;; Sort coupons by usage percentage descending.
(defn sort-coupons-by-usage [(coupons : Any)] : Any
  (reverse (sort-by coupon-current-uses coupons)))

;; Sort coupons by remaining uses ascending (fewest remaining first).
(defn sort-coupons-by-remaining [(coupons : Any)] : Any
  (sort-by coupon-remaining-uses coupons))

;; Sort rules by min-order-value descending (strictest first).
(defn sort-rules-by-min-order [(rules : Any)] : Any
  (reverse (sort-by promotionrule-min-order-value rules)))

;; ===========================================================================
;; Aggregation — coupon statistics
;; ===========================================================================

;; Total number of uses across all coupons.
(defn total-coupon-uses [(coupons : Any)] : Long
  (reduce (fn [acc c] (+ acc (coupon-current-uses c))) 0 coupons))

;; Total max-uses capacity across all coupons.
(defn total-coupon-capacity [(coupons : Any)] : Long
  (reduce (fn [acc c] (+ acc (coupon-max-uses c))) 0 coupons))

;; Overall usage percentage across all coupons.
(defn overall-coupon-usage-pct [(coupons : Any)] : Long
  (let [cap (total-coupon-capacity coupons)]
    (if (= cap 0) 0
        (quot (* (total-coupon-uses coupons) 100) cap))))

;; Average discount value across all coupons.
(defn avg-coupon-discount-value [(coupons : Any)] : Long
  (let [cnt (count coupons)]
    (if (= cnt 0) 0
        (quot (reduce (fn [acc c] (+ acc (coupon-discount-value c))) 0 coupons)
              cnt))))

;; Average uses per coupon.
(defn avg-coupon-uses [(coupons : Any)] : Long
  (let [cnt (count coupons)]
    (if (= cnt 0) 0
        (quot (total-coupon-uses coupons) cnt))))

;; The coupon with the highest current usage count.
(defn most-used-coupon [(coupons : Any)] : Any
  (if (empty? coupons)
      nil
      (reduce (fn [best c]
                (if (> (coupon-current-uses c) (coupon-current-uses best))
                    c best))
              (first coupons) (rest coupons))))

;; The coupon with the least remaining uses (closest to exhaustion,
;; among those still valid).
(defn nearly-exhausted-coupon [(coupons : Any)] : Any
  (let [valid (valid-coupons coupons)]
    (if (empty? valid)
        nil
        (reduce (fn [best c]
                  (if (< (coupon-remaining-uses c) (coupon-remaining-uses best))
                      c best))
                (first valid) (rest valid)))))

;; ===========================================================================
;; Aggregation — campaign statistics
;; ===========================================================================

;; Total uses across all coupons for every campaign in the list.
(defn total-campaign-uses [(campaigns : Any) (coupons : Any)] : Long
  (reduce (fn [acc camp]
            (+ acc (campaign-total-uses coupons (campaign-id camp))))
          0 campaigns))

;; Average uses per campaign.
(defn avg-uses-per-campaign [(campaigns : Any) (coupons : Any)] : Long
  (let [cnt (count campaigns)]
    (if (= cnt 0) 0
        (quot (total-campaign-uses campaigns coupons) cnt))))

;; Campaign with the most total coupon uses.
(defn most-popular-campaign [(campaigns : Any) (coupons : Any)] : Any
  (if (empty? campaigns)
      nil
      (reduce (fn [best camp]
                (if (> (campaign-total-uses coupons (campaign-id camp))
                       (campaign-total-uses coupons (campaign-id best)))
                    camp best))
              (first campaigns) (rest campaigns))))

;; Campaign with the most coupons defined.
(defn campaign-with-most-coupons [(campaigns : Any) (coupons : Any)] : Any
  (if (empty? campaigns)
      nil
      (reduce (fn [best camp]
                (if (> (campaign-coupon-count coupons (campaign-id camp))
                       (campaign-coupon-count coupons (campaign-id best)))
                    camp best))
              (first campaigns) (rest campaigns))))

;; ===========================================================================
;; Aggregation — rule statistics
;; ===========================================================================

;; How many rules exist across all campaigns.
(defn total-rule-count [(rules : Any)] : Long
  (count rules))

;; Average min-order-value across all rules.
(defn avg-rule-min-order [(rules : Any)] : Long
  (let [cnt (count rules)]
    (if (= cnt 0) 0
        (quot (reduce (fn [acc r] (+ acc (promotionrule-min-order-value r)))
                      0 rules)
              cnt))))

;; Highest min-order-value among all rules.
(defn max-rule-min-order [(rules : Any)] : Long
  (if (empty? rules)
      0
      (reduce (fn [best r]
                (if (> (promotionrule-min-order-value r) best)
                    (promotionrule-min-order-value r) best))
              0 rules)))

;; Count rules grouped by min-tier requirement.
(defn rule-count-by-tier [(rules : Any) (tier : String)] : Long
  (count (filterv (fn [r] (= (promotionrule-min-tier r) tier)) rules)))

;; ===========================================================================
;; Cross-module analytics — orders + promotions
;; ===========================================================================

;; Total discount given to a specific customer's orders.
(defn customer-total-discount [(orders : Any) (cust-id : Long)] : Long
  (let [cust-orders (ord/orders-by-customer orders cust-id)]
    (reduce (fn [acc o] (+ acc (ord/order-discount o))) 0 cust-orders)))

;; Average discount per order for a customer.
(defn customer-avg-discount [(orders : Any) (cust-id : Long)] : Long
  (let [cust-orders (ord/orders-by-customer orders cust-id)
        cnt (count cust-orders)]
    (if (= cnt 0) 0
        (quot (customer-total-discount orders cust-id) cnt))))

;; Discount as a percentage of order subtotals for a customer.
(defn customer-discount-pct [(orders : Any) (cust-id : Long)] : Long
  (let [cust-orders (ord/orders-by-customer orders cust-id)
        subtotal-sum (reduce (fn [acc o] (+ acc (ord/order-subtotal o)))
                             0 cust-orders)
        discount-sum (customer-total-discount orders cust-id)]
    (if (= subtotal-sum 0) 0
        (quot (* discount-sum 100) subtotal-sum))))

;; Orders whose discount exceeds a given threshold.
(defn orders-with-discount-above [(orders : Any) (threshold : Long)] : Any
  (filterv (fn [o] (> (ord/order-discount o) threshold)) orders))

;; Count of orders that received any discount at all.
(defn discounted-order-count [(orders : Any)] : Long
  (count (filterv (fn [o] (> (ord/order-discount o) 0)) orders)))

;; Percentage of orders that received a discount.
(defn discount-frequency-pct [(orders : Any)] : Long
  (let [total (count orders)]
    (if (= total 0) 0
        (quot (* (discounted-order-count orders) 100) total))))

;; Average discount for orders that received a non-zero discount.
(defn avg-discount-per-discounted-order [(orders : Any)] : Long
  (let [discounted (filterv (fn [o] (> (ord/order-discount o) 0)) orders)
        cnt (count discounted)]
    (if (= cnt 0) 0
        (quot (reduce (fn [acc o] (+ acc (ord/order-discount o))) 0 discounted)
              cnt))))

;; ===========================================================================
;; Cross-module analytics — catalog + promotions
;; ===========================================================================

;; Coupons for the campaign(s) whose rules target a given category.
(defn coupons-for-category [(coupons : Any) (rules : Any) (cat-id : Long)] : Any
  (let [cat-rules (rules-for-category rules cat-id)
        camp-ids (distinct (mapv promotionrule-campaign-id cat-rules))]
    (filterv (fn [c]
               (some (fn [cid] (= cid (coupon-campaign-id c))) camp-ids))
             coupons)))

;; Number of active campaigns that have rules targeting a category.
(defn category-campaign-count [(campaigns : Any) (rules : Any)
                               (cat-id : Long) (now : Long)] : Long
  (let [cat-rules (rules-for-category rules cat-id)
        camp-ids (distinct (mapv promotionrule-campaign-id cat-rules))
        active (active-campaigns campaigns now)]
    (count (filterv (fn [camp]
                      (some (fn [cid] (= cid (campaign-id camp))) camp-ids))
                    active))))

;; ===========================================================================
;; Cross-module analytics — customers + promotions
;; ===========================================================================

;; Count of customers at or above a given tier.
(defn customers-qualifying-for-tier [(customers : Any) (min-tier : String)] : Any
  (filterv (fn [c] (tier-qualifies? (cust/customer-tier c) min-tier))
           customers))

;; How many customers pass the tier gate of a specific rule.
(defn rule-eligible-customer-count [(rule : PromotionRule) (customers : Any)] : Long
  (count (customers-qualifying-for-tier customers (promotionrule-min-tier rule))))

;; ===========================================================================
;; Coupon simulation — what-if analysis
;; ===========================================================================

;; Simulate applying a coupon to an order total, returning a map with
;; :original, :discount, :final.
(defn simulate-coupon [(coupon : Coupon) (order-total : Long)] : Any
  (let [disc (coupon-discount-amount coupon order-total)
        final (- order-total disc)]
    {:original order-total :discount disc :final final}))

;; Simulate applying every valid coupon to an order total and return a
;; vector of {coupon-id discount final} maps.
(defn simulate-all-coupons [(coupons : Any) (order-total : Long)] : Any
  (mapv (fn [c]
          (let [disc (coupon-discount-amount c order-total)]
            {:coupon-id (coupon-id c)
             :code (coupon-code c)
             :discount disc
             :final (- order-total disc)}))
        (valid-coupons coupons)))

;; ===========================================================================
;; Bulk operations
;; ===========================================================================

;; Use every valid coupon once (batch redemption).  Returns updated
;; coupon vector.
(defn bulk-use-coupons [(coupons : Any)] : Any
  (mapv (fn [c] (if (coupon-valid? c) (use-coupon c) c)) coupons))

;; Deactivate all campaigns whose end-date has passed `now`.
(defn deactivate-expired [(campaigns : Any) (now : Long)] : Any
  (mapv (fn [c]
          (if (and (= (campaign-status c) "active")
                   (< (campaign-end-date c) now))
              (deactivate-campaign c)
              c))
        campaigns))

;; Reset all coupon usages for a campaign (e.g. new period).
(defn reset-campaign-coupons [(coupons : Any) (cid : Long)] : Any
  (mapv (fn [c]
          (if (= (coupon-campaign-id c) cid)
              (reset-coupon-uses c)
              c))
        coupons))

;; ===========================================================================
;; Summary / dashboard
;; ===========================================================================

;; High-level promotion system summary as a map.
(defn promotions-dashboard [(campaigns : Any) (coupons : Any) (rules : Any)
                            (orders : Any) (now : Long)] : Any
  (let [active (active-campaigns campaigns now)
        total-uses (total-coupon-uses coupons)
        total-cap (total-coupon-capacity coupons)
        total-disc (total-discount-given coupons orders)]
    {:active-campaigns (count active)
     :total-campaigns (count campaigns)
     :total-coupons (count coupons)
     :valid-coupons (count (valid-coupons coupons))
     :exhausted-coupons (count (exhausted-coupons coupons))
     :total-uses total-uses
     :total-capacity total-cap
     :usage-pct (if (= total-cap 0) 0 (quot (* total-uses 100) total-cap))
     :total-discount total-disc
     :total-rules (count rules)}))

;; Per-campaign breakdown returning a vector of summary maps.
(defn campaign-breakdown [(campaigns : Any) (coupons : Any) (rules : Any)] : Any
  (mapv (fn [camp]
          (let [cid (campaign-id camp)
                camp-coupons (coupons-for-campaign coupons cid)
                camp-rules (find-rules-for-campaign rules cid)]
            {:campaign-id cid
             :name (campaign-name camp)
             :status (campaign-status camp)
             :coupon-count (count camp-coupons)
             :rule-count (count camp-rules)
             :total-uses (campaign-total-uses coupons cid)
             :valid-coupons (count (valid-coupons camp-coupons))
             :exhausted-coupons (count (exhausted-coupons camp-coupons))}))
        campaigns))

;; Per-coupon effectiveness report.
(defn coupon-effectiveness-report [(coupons : Any)] : Any
  (mapv (fn [c]
          {:coupon-id (coupon-id c)
           :code (coupon-code c)
           :type (coupon-discount-type c)
           :value (coupon-discount-value c)
           :uses (coupon-current-uses c)
           :max-uses (coupon-max-uses c)
           :usage-pct (coupon-usage-pct c)
           :remaining (coupon-remaining-uses c)
           :exhausted (coupon-exhausted? c)})
        coupons))

;; Tier distribution report: for each tier, how many rules require it.
(defn tier-distribution [(rules : Any)] : Any
  {:any (rule-count-by-tier rules "")
   :bronze (rule-count-by-tier rules "bronze")
   :silver (rule-count-by-tier rules "silver")
   :gold (rule-count-by-tier rules "gold")})

;; ===========================================================================
;; Top-N queries
;; ===========================================================================

;; Top N coupons by usage count.
(defn top-coupons-by-usage [(coupons : Any) (n : Long)] : Any
  (vec (take n (reverse (sort-by coupon-current-uses coupons)))))

;; Top N coupons by discount value.
(defn top-coupons-by-value [(coupons : Any) (n : Long)] : Any
  (vec (take n (sort-coupons-by-value coupons))))

;; Top N campaigns by total uses.
(defn top-campaigns-by-uses [(campaigns : Any) (coupons : Any) (n : Long)] : Any
  (vec (take n (reverse
                (sort-by (fn [camp] (campaign-total-uses coupons (campaign-id camp)))
                         campaigns)))))

;; ===========================================================================
;; Coupon code helpers
;; ===========================================================================

;; Check whether a code already exists in the coupon set.
(defn code-exists? [(coupons : Any) (code : String)] : Boolean
  (some? (find-coupon-by-code coupons code)))

;; All unique coupon codes.
(defn all-coupon-codes [(coupons : Any)] : Any
  (mapv coupon-code coupons))

;; Unique campaign ids referenced by coupons.
(defn coupon-campaign-ids [(coupons : Any)] : Any
  (distinct (mapv coupon-campaign-id coupons)))

;; ===========================================================================
;; Discount type analysis
;; ===========================================================================

;; Count coupons by discount type.
(defn coupon-count-by-type [(coupons : Any) (dtype : String)] : Long
  (count (filterv (fn [c] (= (coupon-discount-type c) dtype)) coupons)))

;; Breakdown of coupons by discount type.
(defn discount-type-distribution [(coupons : Any)] : Any
  {:percentage (coupon-count-by-type coupons "percentage")
   :fixed (coupon-count-by-type coupons "fixed")})

;; Average discount-value for a given discount type.
(defn avg-discount-by-type [(coupons : Any) (dtype : String)] : Long
  (let [typed (filterv (fn [c] (= (coupon-discount-type c) dtype)) coupons)
        cnt (count typed)]
    (if (= cnt 0) 0
        (quot (reduce (fn [acc c] (+ acc (coupon-discount-value c))) 0 typed)
              cnt))))

;; ===========================================================================
;; Stacking / combination analysis
;; ===========================================================================

;; Can two coupons be combined?  Simple rule: they must belong to
;; different campaigns.
(defn coupons-stackable? [(c1 : Coupon) (c2 : Coupon)] : Boolean
  (not= (coupon-campaign-id c1) (coupon-campaign-id c2)))

;; Total discount when stacking two coupons on an order total.
;; Applies each coupon's discount independently and sums, capped at
;; order-total.
(defn stacked-discount [(c1 : Coupon) (c2 : Coupon) (order-total : Long)] : Long
  (let [d1 (coupon-discount-amount c1 order-total)
        d2 (coupon-discount-amount c2 order-total)
        raw (+ d1 d2)]
    (if (> raw order-total) order-total raw)))

;; Find the best pair of stackable coupons for an order total.
;; Returns the combined discount amount (0 if no stackable pair).
(defn best-stacked-discount [(coupons : Any) (order-total : Long)] : Long
  (let [valid (valid-coupons coupons)]
    (if (< (count valid) 2)
        0
        (reduce (fn [best-val c1]
                  (reduce (fn [inner-best c2]
                            (if (and (coupons-stackable? c1 c2)
                                     (> (stacked-discount c1 c2 order-total)
                                        inner-best))
                                (stacked-discount c1 c2 order-total)
                                inner-best))
                          best-val valid))
                0 valid))))

;; ===========================================================================
;; Min-order analysis
;; ===========================================================================

;; Lowest min-order among all valid coupons.
(defn lowest-min-order [(coupons : Any)] : Long
  (let [valid (valid-coupons coupons)]
    (if (empty? valid)
        0
        (reduce (fn [best c]
                  (if (< (coupon-min-order c) best)
                      (coupon-min-order c) best))
                (coupon-min-order (first valid)) (rest valid)))))

;; Highest min-order among all valid coupons.
(defn highest-min-order [(coupons : Any)] : Long
  (let [valid (valid-coupons coupons)]
    (if (empty? valid)
        0
        (reduce (fn [best c]
                  (if (> (coupon-min-order c) best)
                      (coupon-min-order c) best))
                (coupon-min-order (first valid)) (rest valid)))))

;; Average min-order threshold across all coupons.
(defn avg-min-order [(coupons : Any)] : Long
  (let [cnt (count coupons)]
    (if (= cnt 0) 0
        (quot (reduce (fn [acc c] (+ acc (coupon-min-order c))) 0 coupons)
              cnt))))
