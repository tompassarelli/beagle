#lang beagle

(ns employees)
(define-mode strict)

(require catalog :as cat)
(require orders :as ord)

;; --- scalars ---------------------------------------------------------------

(defscalar EmployeeId Long)

;; --- records ---------------------------------------------------------------

(defrecord Employee [(id : EmployeeId) (name : String) (department : String)
                     (role : String) (hire-date : ord/Timestamp) (active : Boolean)])

(defrecord CommissionRule [(id : Long) (employee-id : EmployeeId)
                           (category-id : cat/CategoryId) (rate-pct : Long)])

(defrecord SalesTarget [(id : Long) (employee-id : EmployeeId) (period : String)
                        (target-amount : ord/Amount) (actual-amount : ord/Amount)])

;; --- employee operations ---------------------------------------------------

(defn find-employee-by-id [(employees : Any) (id : EmployeeId)] : Any
  (first (filterv (fn [e] (= (employeeid-value (employee-id e)) (employeeid-value id))) employees)))

(defn active-employees [(employees : Any)] : Any
  (filterv (fn [e] (employee-active e)) employees))

(defn employees-by-department [(employees : Any) (dept : String)] : Any
  (filterv (fn [e] (= (employee-department e) dept)) employees))

(defn employees-by-role [(employees : Any) (role : String)] : Any
  (filterv (fn [e] (= (employee-role e) role)) employees))

(defn employee-tenure-days [(employee : Employee) (now : ord/Timestamp)] : Long
  (quot (- (ord/timestamp-value now) (ord/timestamp-value (employee-hire-date employee))) 86400))

(defn senior-employees [(employees : Any) (now : ord/Timestamp) (min-days : Long)] : Any
  (filterv (fn [(e : Employee)]
             (>= (employee-tenure-days e now) min-days))
           employees))

;; --- commission operations -------------------------------------------------

(defn rules-for-employee [(rules : Any) (employee-id : EmployeeId)] : Any
  (filterv (fn [r] (= (employeeid-value (commissionrule-employee-id r)) (employeeid-value employee-id))) rules))

(defn commission-rate [(rules : Any) (employee-id : EmployeeId) (category-id : cat/CategoryId)] : Long
  (let [matches (filterv (fn [r]
                           (and (= (employeeid-value (commissionrule-employee-id r)) (employeeid-value employee-id))
                                (= (cat/categoryid-value (commissionrule-category-id r)) (cat/categoryid-value category-id))))
                         rules)]
    (if (empty? matches)
        0
        (commissionrule-rate-pct (first matches)))))

(defn line-commission [(rules : Any) (employee-id : EmployeeId)
                       (product : Any) (ol : Any)] : ord/Amount
  (let [cat-id (cat/product-category-id product)
        rate (commission-rate rules employee-id cat-id)
        amount (ord/amount-value (ord/orderline-line-total ol))]
    (ord/->Amount (quot (* rate amount) 100))))

(defn order-commission [(rules : Any) (employee-id : EmployeeId)
                        (order : Any) (products : Any)] : ord/Amount
  (let [lines (ord/order-lines order)]
    (ord/->Amount (reduce (fn [acc ol]
              (let [prod-id (ord/orderline-product-id ol)
                    product (cat/find-product-by-id products prod-id)]
                (if (nil? product)
                    acc
                    (+ acc (ord/amount-value (line-commission rules employee-id product ol))))))
            0 lines))))

(defn total-commission [(rules : Any) (employee-id : EmployeeId)
                        (orders : Any) (products : Any)] : ord/Amount
  (ord/->Amount (reduce (fn [acc o]
            (+ acc (ord/amount-value (order-commission rules employee-id o products))))
          0 orders)))

(defn top-earner [(rules : Any) (employees : Any)
                  (orders : Any) (products : Any)] : Any
  (let [actives (active-employees employees)]
    (if (empty? actives)
        nil
        (reduce (fn [best e]
                  (let [best-comm (ord/amount-value (total-commission rules (employee-id best) orders products))
                        curr-comm (ord/amount-value (total-commission rules (employee-id e) orders products))]
                    (if (> curr-comm best-comm) e best)))
                (first actives) (rest actives)))))

;; --- target operations -----------------------------------------------------

(defn targets-for-employee [(targets : Any) (employee-id : EmployeeId)] : Any
  (filterv (fn [t] (= (employeeid-value (salestarget-employee-id t)) (employeeid-value employee-id))) targets))

(defn target-for-period [(targets : Any) (employee-id : EmployeeId)
                         (period : String)] : Any
  (first (filterv (fn [t]
                    (and (= (employeeid-value (salestarget-employee-id t)) (employeeid-value employee-id))
                         (= (salestarget-period t) period)))
                  targets)))

(defn target-achievement-pct [(target : SalesTarget)] : Long
  (let [ta (ord/amount-value (salestarget-target-amount target))]
    (if (= ta 0)
        0
        (quot (* (ord/amount-value (salestarget-actual-amount target)) 100) ta))))

(defn on-target? [(target : SalesTarget)] : Boolean
  (>= (target-achievement-pct target) 100))

(defn targets-met-count [(targets : Any) (employee-id : EmployeeId)] : Long
  (let [emp-targets (targets-for-employee targets employee-id)]
    (count (filterv (fn [(t : SalesTarget)] (on-target? t)) emp-targets))))

(defn update-actual [(target : SalesTarget) (amount : ord/Amount)] : SalesTarget
  (->SalesTarget (salestarget-id target)
                 (salestarget-employee-id target)
                 (salestarget-period target)
                 (salestarget-target-amount target)
                 amount))

;; --- department analytics --------------------------------------------------

(defn department-headcount [(employees : Any) (dept : String)] : Long
  (count (employees-by-department employees dept)))

(defn department-total-commission [(rules : Any) (employees : Any)
                                   (dept : String) (orders : Any)
                                   (products : Any)] : ord/Amount
  (let [dept-emps (employees-by-department employees dept)]
    (ord/->Amount (reduce (fn [acc e]
              (+ acc (ord/amount-value (total-commission rules (employee-id e) orders products))))
            0 dept-emps))))

(defn avg-commission-per-employee [(rules : Any) (employees : Any)
                                   (orders : Any) (products : Any)] : ord/Amount
  (let [actives (active-employees employees)
        cnt (count actives)]
    (if (= cnt 0)
        (ord/->Amount 0)
        (let [total (reduce (fn [acc e]
                              (+ acc (ord/amount-value (total-commission rules (employee-id e)
                                                       orders products))))
                            0 actives)]
          (ord/->Amount (quot total cnt))))))

;; --- employee formatting ---------------------------------------------------

(defn employee-summary [(e : Employee)] : String
  (str (employee-name e) " (" (employee-department e) "/" (employee-role e) ")"))

(defn employee-detail [(e : Employee) (now : ord/Timestamp)] : String
  (str (employee-name e)
       " | Dept: " (employee-department e)
       " | Role: " (employee-role e)
       " | Tenure: " (employee-tenure-days e now) " days"
       " | Active: " (employee-active e)))

;; --- employee validation ---------------------------------------------------

(defn valid-employee? [(e : Employee)] : Boolean
  (and (> (employeeid-value (employee-id e)) 0)
       (not= (employee-name e) "")
       (not= (employee-department e) "")
       (not= (employee-role e) "")))

(defn valid-commission-rule? [(r : CommissionRule)] : Boolean
  (and (> (commissionrule-id r) 0)
       (> (employeeid-value (commissionrule-employee-id r)) 0)
       (> (cat/categoryid-value (commissionrule-category-id r)) 0)
       (> (commissionrule-rate-pct r) 0)
       (<= (commissionrule-rate-pct r) 100)))

(defn valid-sales-target? [(t : SalesTarget)] : Boolean
  (and (> (salestarget-id t) 0)
       (> (employeeid-value (salestarget-employee-id t)) 0)
       (not= (salestarget-period t) "")
       (> (ord/amount-value (salestarget-target-amount t)) 0)
       (>= (ord/amount-value (salestarget-actual-amount t)) 0)))

;; --- commission analysis ---------------------------------------------------

(defn employee-commission-breakdown [(rules : Any) (employee-id : EmployeeId)
                                     (orders : Any) (products : Any)] : Any
  (let [emp-rules (rules-for-employee rules employee-id)]
    (mapv (fn [r]
            (let [cat-id (commissionrule-category-id r)
                  rate (commissionrule-rate-pct r)
                  cat-commission (reduce
                    (fn [acc o]
                      (let [lines (ord/order-lines o)]
                        (+ acc (reduce
                          (fn [a ol]
                            (let [prod-id (ord/orderline-product-id ol)
                                  product (cat/find-product-by-id products prod-id)]
                              (if (nil? product)
                                  a
                                  (if (= (cat/categoryid-value (cat/product-category-id product)) (cat/categoryid-value cat-id))
                                      (+ a (quot (* rate (ord/amount-value (ord/orderline-line-total ol))) 100))
                                      a))))
                          0 lines))))
                    0 orders)]
              {:category-id cat-id :rate rate :commission (ord/->Amount cat-commission)}))
          emp-rules)))

(defn employee-top-category [(rules : Any) (employee-id : EmployeeId)
                              (orders : Any) (products : Any)] : cat/CategoryId
  (let [breakdown (employee-commission-breakdown rules employee-id orders products)]
    (if (empty? breakdown)
        (cat/->CategoryId 0)
        (let [best (reduce (fn [b item]
                             (if (> (ord/amount-value (:commission item)) (ord/amount-value (:commission b))) item b))
                           (first breakdown) (rest breakdown))]
          (:category-id best)))))

;; --- target analysis -------------------------------------------------------

(defn employee-target-summary [(targets : Any) (employee-id : EmployeeId)] : Any
  (let [emp-targets (targets-for-employee targets employee-id)
        total-target (reduce (fn [acc t] (+ acc (ord/amount-value (salestarget-target-amount t))))
                             0 emp-targets)
        total-actual (reduce (fn [acc t] (+ acc (ord/amount-value (salestarget-actual-amount t))))
                             0 emp-targets)
        met (targets-met-count targets employee-id)]
    {:total-target (ord/->Amount total-target)
     :total-actual (ord/->Amount total-actual)
     :targets-met met
     :total-targets (count emp-targets)}))

(defn best-performing-period [(targets : Any) (employee-id : EmployeeId)] : Any
  (let [emp-targets (targets-for-employee targets employee-id)]
    (if (empty? emp-targets)
        nil
        (let [best (reduce (fn [(b : SalesTarget) (t : SalesTarget)]
                             (if (> (target-achievement-pct t)
                                    (target-achievement-pct b))
                                 t b))
                           (first emp-targets) (rest emp-targets))]
          (salestarget-period best)))))

(defn worst-performing-period [(targets : Any) (employee-id : EmployeeId)] : Any
  (let [emp-targets (targets-for-employee targets employee-id)]
    (if (empty? emp-targets)
        nil
        (let [worst (reduce (fn [(b : SalesTarget) (t : SalesTarget)]
                              (if (< (target-achievement-pct t)
                                     (target-achievement-pct b))
                                  t b))
                            (first emp-targets) (rest emp-targets))]
          (salestarget-period worst)))))

;; --- department comparison -------------------------------------------------

(defn department-avg-tenure [(employees : Any) (dept : String) (now : ord/Timestamp)] : Long
  (let [dept-emps (employees-by-department employees dept)
        cnt (count dept-emps)]
    (if (= cnt 0)
        0
        (quot (reduce (fn [acc (e : Employee)]
                        (+ acc (employee-tenure-days e now)))
                      0 dept-emps)
              cnt))))

(defn department-active-count [(employees : Any) (dept : String)] : Long
  (count (filterv (fn [e] (and (= (employee-department e) dept)
                               (employee-active e)))
                  employees)))

(defn department-active-pct [(employees : Any) (dept : String)] : Long
  (let [total (department-headcount employees dept)]
    (if (= total 0)
        0
        (quot (* (department-active-count employees dept) 100) total))))

;; --- bulk operations -------------------------------------------------------

(defn deactivate-employee [(employees : Any) (target-id : EmployeeId)] : Any
  (mapv (fn [(e : Employee)]
          (if (= (employeeid-value (employee-id e)) (employeeid-value target-id))
              (->Employee (employee-id e) (employee-name e)
                          (employee-department e) (employee-role e)
                          (employee-hire-date e) false)
              e))
        employees))

(defn activate-employee [(employees : Any) (target-id : EmployeeId)] : Any
  (mapv (fn [(e : Employee)]
          (if (= (employeeid-value (employee-id e)) (employeeid-value target-id))
              (->Employee (employee-id e) (employee-name e)
                          (employee-department e) (employee-role e)
                          (employee-hire-date e) true)
              e))
        employees))

(defn change-department [(employee : Employee) (new-dept : String)] : Employee
  (->Employee (employee-id employee) (employee-name employee)
              new-dept (employee-role employee)
              (employee-hire-date employee) (employee-active employee)))

(defn change-role [(employee : Employee) (new-role : String)] : Employee
  (->Employee (employee-id employee) (employee-name employee)
              (employee-department employee) new-role
              (employee-hire-date employee) (employee-active employee)))

;; --- commission rule management --------------------------------------------

(defn add-commission-rule [(rules : Any) (rule : CommissionRule)] : Any
  (conj rules rule))

(defn remove-commission-rule [(rules : Any) (rule-id : Long)] : Any
  (filterv (fn [r] (not= (commissionrule-id r) rule-id)) rules))

(defn update-commission-rate [(rules : Any) (rule-id : Long) (new-rate : Long)] : Any
  (mapv (fn [(r : CommissionRule)]
          (if (= (commissionrule-id r) rule-id)
              (->CommissionRule (commissionrule-id r)
                                (commissionrule-employee-id r)
                                (commissionrule-category-id r)
                                new-rate)
              r))
        rules))

;; --- cross-module: order attribution ---------------------------------------

(defn employee-order-count [(employee-id : EmployeeId) (orders : Any)] : Long
  (count orders))

(defn employee-revenue [(rules : Any) (employee-id : EmployeeId)
                        (orders : Any) (products : Any)] : ord/Amount
  (total-commission rules employee-id orders products))

;; --- ranking ---------------------------------------------------------------

(defn rank-by-commission [(rules : Any) (employees : Any)
                          (orders : Any) (products : Any)] : Any
  (let [actives (active-employees employees)]
    (reverse (sort-by (fn [e]
                        (ord/amount-value (total-commission rules (employee-id e) orders products)))
                      actives))))

(defn rank-by-tenure [(employees : Any) (now : ord/Timestamp)] : Any
  (reverse (sort-by (fn [(e : Employee)] (employee-tenure-days e now))
                    employees)))

(defn commission-leaderboard [(rules : Any) (employees : Any)
                               (orders : Any) (products : Any)] : Any
  (let [ranked (rank-by-commission rules employees orders products)]
    (mapv (fn [e]
            {:employee-id (employee-id e)
             :name (employee-name e)
             :commission (total-commission rules (employee-id e) orders products)})
          ranked)))

;; --- statistics ------------------------------------------------------------

(defn total-headcount [(employees : Any)] : Long
  (count employees))

(defn active-headcount [(employees : Any)] : Long
  (count (active-employees employees)))

(defn turnover-rate-pct [(employees : Any)] : Long
  (let [total (total-headcount employees)]
    (if (= total 0)
        0
        (let [inactive (- total (active-headcount employees))]
          (quot (* inactive 100) total)))))

(defn unique-departments [(employees : Any)] : Any
  (distinct (mapv employee-department employees)))

(defn unique-roles [(employees : Any)] : Any
  (distinct (mapv employee-role employees)))

(defn department-roster [(employees : Any) (dept : String)] : Any
  (let [dept-emps (employees-by-department employees dept)]
    (mapv (fn [e]
            {:id (employee-id e)
             :name (employee-name e)
             :role (employee-role e)
             :active (employee-active e)})
          dept-emps)))

;; --- target gap analysis ---------------------------------------------------

(defn target-gap [(target : SalesTarget)] : ord/Amount
  (let [diff (- (ord/amount-value (salestarget-target-amount target))
                (ord/amount-value (salestarget-actual-amount target)))]
    (if (> diff 0) (ord/->Amount diff) (ord/->Amount 0))))

(defn target-surplus [(target : SalesTarget)] : ord/Amount
  (let [diff (- (ord/amount-value (salestarget-actual-amount target))
                (ord/amount-value (salestarget-target-amount target)))]
    (if (> diff 0) (ord/->Amount diff) (ord/->Amount 0))))

(defn employee-total-target [(targets : Any) (employee-id : EmployeeId)] : ord/Amount
  (let [emp-targets (targets-for-employee targets employee-id)]
    (ord/->Amount (reduce (fn [acc t] (+ acc (ord/amount-value (salestarget-target-amount t)))) 0 emp-targets))))

(defn employee-total-actual [(targets : Any) (employee-id : EmployeeId)] : ord/Amount
  (let [emp-targets (targets-for-employee targets employee-id)]
    (ord/->Amount (reduce (fn [acc t] (+ acc (ord/amount-value (salestarget-actual-amount t)))) 0 emp-targets))))

(defn employee-total-gap [(targets : Any) (employee-id : EmployeeId)] : ord/Amount
  (let [emp-targets (targets-for-employee targets employee-id)]
    (ord/->Amount (reduce (fn [acc (t : SalesTarget)] (+ acc (ord/amount-value (target-gap t)))) 0 emp-targets))))

(defn employee-total-surplus [(targets : Any) (employee-id : EmployeeId)] : ord/Amount
  (let [emp-targets (targets-for-employee targets employee-id)]
    (ord/->Amount (reduce (fn [acc (t : SalesTarget)] (+ acc (ord/amount-value (target-surplus t)))) 0 emp-targets))))

(defn employee-overall-achievement-pct [(targets : Any) (employee-id : EmployeeId)] : Long
  (let [total-tgt (ord/amount-value (employee-total-target targets employee-id))]
    (if (= total-tgt 0)
        0
        (quot (* (ord/amount-value (employee-total-actual targets employee-id)) 100) total-tgt))))

;; --- commission thresholds -------------------------------------------------

(defn employees-above-commission [(rules : Any) (employees : Any)
                                   (orders : Any) (products : Any)
                                   (threshold : ord/Amount)] : Any
  (filterv (fn [e]
             (>= (ord/amount-value (total-commission rules (employee-id e) orders products))
                  (ord/amount-value threshold)))
           (active-employees employees)))

(defn employees-below-commission [(rules : Any) (employees : Any)
                                   (orders : Any) (products : Any)
                                   (threshold : ord/Amount)] : Any
  (filterv (fn [e]
             (< (ord/amount-value (total-commission rules (employee-id e) orders products))
                 (ord/amount-value threshold)))
           (active-employees employees)))

(defn commission-spread [(rules : Any) (employees : Any)
                          (orders : Any) (products : Any)] : ord/Amount
  (let [actives (active-employees employees)]
    (if (empty? actives)
        (ord/->Amount 0)
        (let [commissions (mapv (fn [e]
                                  (ord/amount-value (total-commission rules (employee-id e)
                                                    orders products)))
                                actives)
              max-c (apply max commissions)
              min-c (apply min commissions)]
          (ord/->Amount (- max-c min-c))))))

(defn median-commission [(rules : Any) (employees : Any)
                          (orders : Any) (products : Any)] : ord/Amount
  (let [actives (active-employees employees)]
    (if (empty? actives)
        (ord/->Amount 0)
        (let [commissions (sort (mapv (fn [e]
                                        (ord/amount-value (total-commission rules (employee-id e)
                                                          orders products)))
                                      actives))
              cnt (count commissions)
              mid (quot cnt 2)]
          (ord/->Amount (nth commissions mid))))))

;; --- category commission analysis ------------------------------------------

(defn category-total-commission [(rules : Any) (employees : Any)
                                  (category-id : cat/CategoryId) (orders : Any)
                                  (products : Any)] : ord/Amount
  (let [actives (active-employees employees)]
    (ord/->Amount (reduce (fn [acc e]
              (let [rate (commission-rate rules (employee-id e) category-id)]
                (+ acc (reduce
                  (fn [a o]
                    (let [lines (ord/order-lines o)]
                      (+ a (reduce
                        (fn [inner ol]
                          (let [prod-id (ord/orderline-product-id ol)
                                product (cat/find-product-by-id products prod-id)]
                            (if (nil? product)
                                inner
                                (if (= (cat/categoryid-value (cat/product-category-id product)) (cat/categoryid-value category-id))
                                    (+ inner (quot (* rate (ord/amount-value (ord/orderline-line-total ol))) 100))
                                    inner))))
                        0 lines))))
                  0 orders))))
            0 actives))))

(defn category-avg-commission-rate [(rules : Any) (category-id : cat/CategoryId)] : Long
  (let [matching (filterv (fn [r] (= (cat/categoryid-value (commissionrule-category-id r)) (cat/categoryid-value category-id)))
                          rules)
        cnt (count matching)]
    (if (= cnt 0)
        0
        (quot (reduce (fn [acc r] (+ acc (commissionrule-rate-pct r)))
                      0 matching)
              cnt))))

(defn categories-with-rules [(rules : Any)] : Any
  (distinct (mapv commissionrule-category-id rules)))

(defn rules-for-category [(rules : Any) (category-id : cat/CategoryId)] : Any
  (filterv (fn [r] (= (cat/categoryid-value (commissionrule-category-id r)) (cat/categoryid-value category-id))) rules))

(defn category-rule-count [(rules : Any) (category-id : cat/CategoryId)] : Long
  (count (rules-for-category rules category-id)))

;; --- employee performance scoring ------------------------------------------

(defn performance-score [(rules : Any) (targets : Any) (employee-id : EmployeeId)
                          (orders : Any) (products : Any)] : Long
  (let [comm (ord/amount-value (total-commission rules employee-id orders products))
        achievement (employee-overall-achievement-pct targets employee-id)
        met (targets-met-count targets employee-id)]
    (+ (quot comm 100) (* achievement 2) (* met 500))))

(defn rank-by-performance [(rules : Any) (targets : Any) (employees : Any)
                            (orders : Any) (products : Any)] : Any
  (let [actives (active-employees employees)]
    (reverse (sort-by (fn [e]
                        (performance-score rules targets (employee-id e)
                                           orders products))
                      actives))))

(defn top-performers [(rules : Any) (targets : Any) (employees : Any)
                       (orders : Any) (products : Any) (n : Long)] : Any
  (let [ranked (rank-by-performance rules targets employees orders products)]
    (vec (take n ranked))))

(defn bottom-performers [(rules : Any) (targets : Any) (employees : Any)
                          (orders : Any) (products : Any) (n : Long)] : Any
  (let [ranked (rank-by-performance rules targets employees orders products)]
    (vec (take n (reverse ranked)))))

(defn performance-report [(rules : Any) (targets : Any) (employees : Any)
                           (orders : Any) (products : Any)] : Any
  (let [actives (active-employees employees)]
    (mapv (fn [e]
            (let [eid (employee-id e)]
              {:employee-id eid
               :name (employee-name e)
               :department (employee-department e)
               :commission (total-commission rules eid orders products)
               :achievement-pct (employee-overall-achievement-pct targets eid)
               :targets-met (targets-met-count targets eid)
               :score (performance-score rules targets eid orders products)}))
          actives)))

;; --- department commission breakdown ---------------------------------------

(defn department-commission-breakdown [(rules : Any) (employees : Any)
                                       (dept : String) (orders : Any)
                                       (products : Any)] : Any
  (let [dept-emps (employees-by-department employees dept)]
    (mapv (fn [e]
            {:employee-id (employee-id e)
             :name (employee-name e)
             :commission (total-commission rules (employee-id e) orders products)})
          dept-emps)))

(defn department-avg-commission [(rules : Any) (employees : Any)
                                  (dept : String) (orders : Any)
                                  (products : Any)] : ord/Amount
  (let [dept-emps (employees-by-department employees dept)
        cnt (count dept-emps)]
    (if (= cnt 0)
        (ord/->Amount 0)
        (ord/->Amount (quot (ord/amount-value (department-total-commission rules employees dept orders products)) cnt)))))

(defn department-commission-spread [(rules : Any) (employees : Any)
                                     (dept : String) (orders : Any)
                                     (products : Any)] : ord/Amount
  (let [dept-emps (employees-by-department employees dept)]
    (if (empty? dept-emps)
        (ord/->Amount 0)
        (let [commissions (mapv (fn [e]
                                  (ord/amount-value (total-commission rules (employee-id e)
                                                    orders products)))
                                dept-emps)
              max-c (apply max commissions)
              min-c (apply min commissions)]
          (ord/->Amount (- max-c min-c))))))

;; --- employee tenure analysis ----------------------------------------------

(defn newest-employee [(employees : Any)] : Any
  (if (empty? employees)
      nil
      (reduce (fn [newest e]
                (if (> (ord/timestamp-value (employee-hire-date e))
                       (ord/timestamp-value (employee-hire-date newest)))
                    e newest))
              (first employees) (rest employees))))

(defn oldest-employee [(employees : Any)] : Any
  (if (empty? employees)
      nil
      (reduce (fn [oldest e]
                (if (< (ord/timestamp-value (employee-hire-date e))
                       (ord/timestamp-value (employee-hire-date oldest)))
                    e oldest))
              (first employees) (rest employees))))

(defn avg-tenure-days [(employees : Any) (now : ord/Timestamp)] : Long
  (let [cnt (count employees)]
    (if (= cnt 0)
        0
        (quot (reduce (fn [acc (e : Employee)]
                        (+ acc (employee-tenure-days e now)))
                      0 employees)
              cnt))))

(defn tenure-spread-days [(employees : Any) (now : ord/Timestamp)] : Long
  (if (empty? employees)
      0
      (let [tenures (mapv (fn [(e : Employee)] (employee-tenure-days e now))
                          employees)
            max-t (apply max tenures)
            min-t (apply min tenures)]
        (- max-t min-t))))

(defn employees-hired-in-period [(employees : Any) (start : ord/Timestamp) (end : ord/Timestamp)] : Any
  (filterv (fn [e]
             (and (>= (ord/timestamp-value (employee-hire-date e)) (ord/timestamp-value start))
                  (<= (ord/timestamp-value (employee-hire-date e)) (ord/timestamp-value end))))
           employees))

(defn hire-count-in-period [(employees : Any) (start : ord/Timestamp) (end : ord/Timestamp)] : Long
  (count (employees-hired-in-period employees start end)))

;; --- cross-module: order-based attribution ---------------------------------

(defn employee-order-revenue [(rules : Any) (employee-id : EmployeeId)
                               (order : Any) (products : Any)] : ord/Amount
  (order-commission rules employee-id order products))

(defn employee-avg-order-commission [(rules : Any) (employee-id : EmployeeId)
                                     (orders : Any) (products : Any)] : ord/Amount
  (let [cnt (count orders)]
    (if (= cnt 0)
        (ord/->Amount 0)
        (ord/->Amount (quot (ord/amount-value (total-commission rules employee-id orders products)) cnt)))))

(defn employee-highest-commission-order [(rules : Any) (employee-id : EmployeeId)
                                          (orders : Any) (products : Any)] : Any
  (if (empty? orders)
      nil
      (reduce (fn [best o]
                (let [best-comm (ord/amount-value (order-commission rules employee-id best products))
                      curr-comm (ord/amount-value (order-commission rules employee-id o products))]
                  (if (> curr-comm best-comm) o best)))
              (first orders) (rest orders))))

(defn employee-zero-commission-orders [(rules : Any) (employee-id : EmployeeId)
                                        (orders : Any) (products : Any)] : Any
  (filterv (fn [o]
             (= (ord/amount-value (order-commission rules employee-id o products)) 0))
           orders))

;; --- target update helpers -------------------------------------------------

(defn increment-actual [(target : SalesTarget) (amount : ord/Amount)] : SalesTarget
  (->SalesTarget (salestarget-id target)
                 (salestarget-employee-id target)
                 (salestarget-period target)
                 (salestarget-target-amount target)
                 (ord/->Amount (+ (ord/amount-value (salestarget-actual-amount target)) (ord/amount-value amount)))))

(defn update-target-amount [(target : SalesTarget) (new-target : ord/Amount)] : SalesTarget
  (->SalesTarget (salestarget-id target)
                 (salestarget-employee-id target)
                 (salestarget-period target)
                 new-target
                 (salestarget-actual-amount target)))

(defn remaining-to-target [(target : SalesTarget)] : ord/Amount
  (let [gap (target-gap target)]
    gap))

(defn target-completion-rate [(targets : Any) (employee-id : EmployeeId)] : Long
  (let [emp-targets (targets-for-employee targets employee-id)
        cnt (count emp-targets)]
    (if (= cnt 0)
        0
        (quot (* (targets-met-count targets employee-id) 100) cnt))))

;; --- comprehensive summaries -----------------------------------------------

(defn employee-full-report [(rules : Any) (targets : Any) (employee : Employee)
                             (orders : Any) (products : Any) (now : ord/Timestamp)] : Any
  (let [eid (employee-id employee)]
    {:employee-id eid
     :name (employee-name employee)
     :department (employee-department employee)
     :role (employee-role employee)
     :tenure-days (employee-tenure-days employee now)
     :active (employee-active employee)
     :total-commission (total-commission rules eid orders products)
     :achievement-pct (employee-overall-achievement-pct targets eid)
     :targets-met (targets-met-count targets eid)
     :performance-score (performance-score rules targets eid orders products)}))

(defn department-full-report [(rules : Any) (targets : Any) (employees : Any)
                               (dept : String) (orders : Any) (products : Any)
                               (now : ord/Timestamp)] : Any
  (let [dept-emps (employees-by-department employees dept)]
    {:department dept
     :headcount (count dept-emps)
     :active-count (department-active-count employees dept)
     :avg-tenure (department-avg-tenure employees dept now)
     :total-commission (department-total-commission rules employees dept
                                                    orders products)
     :avg-commission (department-avg-commission rules employees dept
                                                orders products)}))

(defn company-summary [(rules : Any) (targets : Any) (employees : Any)
                        (orders : Any) (products : Any) (now : ord/Timestamp)] : Any
  (let [actives (active-employees employees)
        total-comm (reduce (fn [acc e]
                             (+ acc (ord/amount-value (total-commission rules (employee-id e)
                                                      orders products))))
                           0 actives)
        total-met (reduce (fn [acc e]
                            (+ acc (targets-met-count targets (employee-id e))))
                          0 actives)]
    {:total-employees (count employees)
     :active-employees (count actives)
     :departments (count (unique-departments employees))
     :total-commission (ord/->Amount total-comm)
     :avg-commission (if (= (count actives) 0) (ord/->Amount 0)
                         (ord/->Amount (quot total-comm (count actives))))
     :avg-tenure (avg-tenure-days employees now)
     :total-targets-met total-met
     :turnover-rate (turnover-rate-pct employees)}))
