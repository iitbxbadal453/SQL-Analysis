CREATE DATABASE IF NOT EXISTS coffee_shop_db;
USE coffee_shop_db;

/* ------------------
   0. DATA CLEANING
   ---------------- */

SELECT * FROM coffee;

-- Query 1: Row count vs distinct transaction count
SELECT COUNT(*) AS total_rows,
       COUNT(DISTINCT transaction_id) AS distinct_transactions
FROM coffee;

DELETE FROM coffee
WHERE transaction_id IS NULL
   OR transaction_date IS NULL
   OR unit_price IS NULL
   OR transaction_qty IS NULL;

-- Derived revenue column used throughout (stored generated column)
ALTER TABLE coffee
ADD COLUMN revenue DECIMAL(10,2) GENERATED ALWAYS AS (unit_price * transaction_qty) STORED;

SELECT * FROM coffee;

UPDATE coffee
SET transaction_date = STR_TO_DATE(transaction_date, '%d-%m-%Y');

ALTER TABLE coffee
ADD COLUMN order_hour INT GENERATED ALWAYS AS (HOUR(transaction_time)) STORED AFTER transaction_time,
ADD COLUMN order_dow  VARCHAR(10) GENERATED ALWAYS AS (DAYNAME(transaction_date)) STORED AFTER transaction_date,
ADD COLUMN order_month VARCHAR(7) GENERATED ALWAYS AS (DATE_FORMAT(transaction_date,'%Y-%m')) STORED AFTER transaction_date;

ALTER TABLE coffee
MODIFY COLUMN transaction_date DATE,
MODIFY COLUMN transaction_time TIME,
MODIFY COLUMN store_location VARCHAR(255),
MODIFY COLUMN product_category VARCHAR(255),
MODIFY COLUMN product_type VARCHAR(255),
MODIFY COLUMN product_detail VARCHAR(255);

UPDATE coffee
SET transaction_time = STR_TO_DATE(transaction_time, '%H:%i:%s');

CREATE INDEX idx_date ON coffee(transaction_date);
CREATE INDEX idx_product ON coffee(product_type);
CREATE INDEX idx_store ON coffee(store_location);

SELECT * FROM coffee;

/* ----------------------------------------------------------------------------
   1. CORE KPIs
   ---------------------------------------------------------------------------- */

-- Query 2: Headline KPIs - total revenue, orders, items, AOV, avg items/order
SELECT
    ROUND(SUM(revenue), 2)                                   AS total_revenue,
    COUNT(DISTINCT transaction_id)                           AS total_orders,
    SUM(transaction_qty)                                     AS total_items_sold,
    ROUND(SUM(revenue) / COUNT(DISTINCT transaction_id), 2)  AS avg_order_value,
    ROUND(SUM(transaction_qty) / COUNT(DISTINCT transaction_id), 2) AS avg_items_per_order
FROM coffee;


/* ----------------------------------------------------------------------------
   2. SALES TREND OVER TIME
   ---------------------------------------------------------------------------- */

-- Query 3: Monthly revenue with Month-over-Month growth (LAG window function)
WITH monthly AS (
    SELECT order_month,
           ROUND(SUM(revenue), 2) AS revenue,
           COUNT(DISTINCT transaction_id) AS orders
    FROM coffee
    GROUP BY order_month
)

SELECT
    order_month,
    revenue,
    orders,
    revenue - LAG(revenue) OVER (ORDER BY order_month) AS mom_change,
    ROUND(100 * (revenue - LAG(revenue) OVER (ORDER BY order_month))
          / LAG(revenue) OVER (ORDER BY order_month), 2) AS mom_pct_growth
FROM monthly
ORDER BY order_month;

-- Query 4: Rolling 7-day revenue average
WITH daily AS (
    SELECT transaction_date, SUM(revenue) AS revenue
    FROM coffee
    GROUP BY transaction_date
)
SELECT
    transaction_date,
    revenue,
    ROUND(AVG(revenue) OVER (
        ORDER BY transaction_date
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ), 2) AS rolling_7day_avg_revenue
FROM daily
ORDER BY transaction_date;

-- Query 5: Day-of-week pattern (which days drive the most revenue)
SELECT
    order_dow,
    ROUND(SUM(revenue), 2) AS revenue,
    COUNT(DISTINCT transaction_id) AS orders,
    ROUND(SUM(revenue) / COUNT(DISTINCT transaction_id), 2) AS avg_order_value
FROM coffee
GROUP BY order_dow
ORDER BY revenue DESC;

-- Query 6: Hourly demand curve (identify peak hours for staffing/inventory)
SELECT
    order_hour,
    ROUND(SUM(revenue), 2) AS revenue,
    COUNT(DISTINCT transaction_id) AS orders
FROM coffee
GROUP BY order_hour
ORDER BY revenue DESC;


/* ----------------------------------------------------------------------------
   3. CATEGORY PERFORMANCE
   ---------------------------------------------------------------------------- */

-- Query 7: Revenue, quantity, orders and % of total revenue by category
SELECT
    product_category,
    ROUND(SUM(revenue), 2) AS revenue,
    SUM(transaction_qty) AS qty_sold,
    COUNT(DISTINCT transaction_id) AS orders,
    ROUND(100 * SUM(revenue) / (SELECT SUM(revenue) FROM coffee), 2) AS pct_of_total_revenue
FROM coffee
GROUP BY product_category
ORDER BY revenue DESC;

-- Query 8: Category Month-over-Month growth (partitioned LAG window function)
WITH cat_month AS (
    SELECT product_category, order_month, SUM(revenue) AS revenue
    FROM coffee
    GROUP BY product_category, order_month
)
SELECT
    product_category,
    order_month,
    revenue,
    ROUND(100 * (revenue - LAG(revenue) OVER (PARTITION BY product_category ORDER BY order_month))
          / LAG(revenue) OVER (PARTITION BY product_category ORDER BY order_month), 2) AS mom_pct_growth
FROM cat_month
ORDER BY product_category, order_month;


/* ----------------------------------------------------------------------------
   4. TOP & BOTTOM PERFORMING PRODUCTS  (revenue, quantity, orders)
   ---------------------------------------------------------------------------- */

-- Query 9: Top 5 products by revenue
SELECT product_type, ROUND(SUM(revenue),2) AS revenue,
       SUM(transaction_qty) AS qty_sold, COUNT(DISTINCT transaction_id) AS orders
FROM coffee
GROUP BY product_type
ORDER BY revenue DESC
LIMIT 5;

-- Query 10: Bottom 5 products by revenue (candidates to re-price, bundle, or discontinue)
SELECT product_type, ROUND(SUM(revenue),2) AS revenue,
       SUM(transaction_qty) AS qty_sold, COUNT(DISTINCT transaction_id) AS orders
FROM coffee
GROUP BY product_type
ORDER BY revenue ASC
LIMIT 5;

-- Query 11: Top 5 products by quantity sold
SELECT product_type, SUM(transaction_qty) AS qty_sold, ROUND(SUM(revenue),2) AS revenue
FROM coffee
GROUP BY product_type
ORDER BY qty_sold DESC
LIMIT 5;

-- Query 12: Top 5 products by number of orders
SELECT product_type, COUNT(DISTINCT transaction_id) AS orders, ROUND(SUM(revenue),2) AS revenue
FROM coffee
GROUP BY product_type
ORDER BY orders DESC
LIMIT 5;

-- Query 13: Products ranked within their own category (RANK window function) -
--           surfaces the weakest item inside each category, not just overall
WITH product_rev AS (
    SELECT product_category, product_type, SUM(revenue) AS revenue
    FROM coffee
    GROUP BY product_category, product_type
)
SELECT product_category, product_type, ROUND(revenue,2) AS revenue,
       RANK() OVER (PARTITION BY product_category ORDER BY revenue DESC) AS rank_in_category
FROM product_rev
ORDER BY product_category;

-- Query 14: Pareto / ABC analysis - cumulative % of revenue by product
--           (classic 80/20 check: how many products drive 80% of revenue)
WITH prod_rev AS (
    SELECT product_type, SUM(revenue) AS revenue
    FROM coffee
    GROUP BY product_type
),
ranked AS (
    SELECT product_type, revenue,
           SUM(revenue) OVER (ORDER BY revenue DESC
                               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cum_revenue,
           SUM(revenue) OVER () AS total_revenue
    FROM prod_rev
)
SELECT product_type, ROUND(revenue,2) AS revenue,
       ROUND(100 * cum_revenue / total_revenue, 2) AS cum_pct_of_revenue
FROM ranked
ORDER BY revenue DESC;


/* ----------------------------------------------------------------------------
   5. STORE PERFORMANCE
   ---------------------------------------------------------------------------- */

-- Query 15: Store ranking by total revenue and AOV
SELECT
    store_location,
    ROUND(SUM(revenue), 2) AS revenue,
    COUNT(DISTINCT transaction_id) AS orders,
    ROUND(SUM(revenue) / COUNT(DISTINCT transaction_id), 2) AS avg_order_value,
    RANK() OVER (ORDER BY SUM(revenue) DESC) AS store_rank
FROM coffee
GROUP BY store_location;

-- Query 16: Store x category cross-tab (which store under-indexes on which category)
SELECT
    store_location,
    product_category,
    ROUND(SUM(revenue), 2) AS revenue,
    ROUND(100 * SUM(revenue) / SUM(SUM(revenue)) OVER (PARTITION BY store_location), 2) AS pct_of_store_revenue
FROM coffee
GROUP BY store_location, product_category
ORDER BY store_location, revenue DESC;

-- Query 17: Store revenue by month
SELECT store_location, order_month, ROUND(SUM(revenue), 2) AS revenue
FROM coffee
GROUP BY store_location, order_month
ORDER BY store_location, order_month;

-- Query 18: Store rank each month - did the #1 store stay #1? (RANK per partition)
WITH store_month AS (
    SELECT store_location, order_month, SUM(revenue) AS revenue
    FROM coffee
    GROUP BY store_location, order_month
)

SELECT
    store_location, order_month, ROUND(revenue, 2) AS revenue,
    RANK() OVER (PARTITION BY order_month ORDER BY revenue DESC) AS rank_that_month
FROM store_month
ORDER BY order_month, rank_that_month;

-- Query 19: Best-performing store on each day of week (staffing/inventory by location)
WITH store_dow AS (
    SELECT store_location, order_dow, SUM(revenue) AS revenue
    FROM coffee
    GROUP BY store_location, order_dow
),
ranked AS (
    SELECT *, RANK() OVER (PARTITION BY order_dow ORDER BY revenue DESC) AS rnk
    FROM store_dow
)

SELECT store_location, order_dow, ROUND(revenue, 2) AS revenue
FROM ranked
WHERE rnk = 1
ORDER BY order_dow;

/* ----------------------------------------------------------------------------
   6. BASKET / ORDER SIZE BEHAVIOR
   ---------------------------------------------------------------------------- */

-- Query 20: Basket size distribution - items per transaction vs revenue per transaction
WITH basket AS (
    SELECT transaction_id,
           SUM(transaction_qty) AS items_in_order,
           SUM(revenue) AS order_revenue
    FROM coffee
    GROUP BY transaction_id
)
SELECT
    items_in_order,
    COUNT(*) AS num_orders,
    ROUND(AVG(order_revenue), 2) AS avg_order_revenue,
    ROUND(SUM(order_revenue), 2) AS total_revenue
FROM basket
GROUP BY items_in_order
ORDER BY items_in_order;

-- Query 21: Outlier / bulk orders - transactions beyond the 95th percentile of items/order
WITH basket AS (
    SELECT 
        transaction_id, 
        SUM(transaction_qty) AS items_in_order
    FROM coffee
    GROUP BY transaction_id
),
pct AS (
    SELECT 
        transaction_id,
        items_in_order,
        ROUND(PERCENT_RANK() OVER (ORDER BY items_in_order),2) AS pctile
    FROM basket
)

SELECT COUNT(*)
FROM pct
WHERE pctile >= 0.95
ORDER BY items_in_order DESC;

-- Query 22: Revenue contribution by basket-size bucket (small / medium / large orders)
WITH basket AS (
    SELECT transaction_id, SUM(transaction_qty) AS items_in_order, SUM(revenue) AS order_revenue
    FROM coffee
    GROUP BY transaction_id
)

SELECT
    CASE
        WHEN items_in_order <= 2 THEN 'small order'
        WHEN items_in_order BETWEEN 3 AND 4 THEN 'medium order'
        ELSE 'large order'
    END AS basket_size,
    COUNT(*) AS orders,
    ROUND(SUM(order_revenue), 2) AS revenue,
    ROUND(100 * SUM(order_revenue) / SUM(SUM(order_revenue)) OVER (), 2) AS pct_of_total_revenue
FROM basket
GROUP BY basket_size
ORDER BY revenue DESC;

ALTER TABLE coffee
ADD COLUMN order_size VARCHAR(20)
GENERATED ALWAYS AS (
    CASE
        WHEN transaction_qty <= 2 THEN 'small'
        WHEN transaction_qty BETWEEN 3 AND 4 THEN 'medium'
        ELSE 'large'
    END
) STORED
AFTER transaction_qty;

/* ----------------------------------------------------------------------------
   7. TIME-BASED SEGMENTS
   ---------------------------------------------------------------------------- */

-- Query 23: Day-part segmentation (Morning / Midday / Afternoon / Evening)
SELECT
    CASE
        WHEN order_hour BETWEEN 6 AND 10  THEN 'Morning'
        WHEN order_hour BETWEEN 11 AND 14 THEN 'Midday'
        WHEN order_hour BETWEEN 15 AND 18 THEN 'Afternoon'
        ELSE 'Evening'
    END AS day_part,
    ROUND(SUM(revenue), 2) AS revenue,
    COUNT(DISTINCT transaction_id) AS orders,
    ROUND(SUM(revenue) / COUNT(DISTINCT transaction_id), 2) AS avg_order_value
FROM coffee
GROUP BY day_part
ORDER BY revenue DESC;

ALTER TABLE coffee
ADD COLUMN day_part VARCHAR(20)
GENERATED ALWAYS AS (
    CASE
        WHEN order_hour BETWEEN 6 AND 10  THEN 'Morning'
        WHEN order_hour BETWEEN 11 AND 14 THEN 'Midday'
        WHEN order_hour BETWEEN 15 AND 18 THEN 'Afternoon'
        ELSE 'Evening'
    END
) STORED
AFTER order_hour;

-- Query 24: Weekday vs Weekend comparison
SELECT
    CASE WHEN order_dow IN ('Saturday','Sunday') THEN 'Weekend' ELSE 'Weekday' END AS day_type,
    ROUND(SUM(revenue), 2) AS revenue,
    COUNT(DISTINCT transaction_id) AS orders,
    ROUND(SUM(revenue) / COUNT(DISTINCT transaction_id), 2) AS avg_order_value
FROM coffee
GROUP BY day_type;

ALTER TABLE coffee
ADD COLUMN day_type VARCHAR(20)
GENERATED ALWAYS AS (
    CASE
        WHEN order_dow IN ('Saturday','Sunday') THEN 'Weekend'
        ELSE 'Weekday'
	END
) STORED
AFTER order_dow;

-- Query 25: Quarterly revenue trend (executive-level roll-up above monthly)
SELECT
    CONCAT(YEAR(transaction_date), '-Q', QUARTER(transaction_date)) AS order_quarter,
    ROUND(SUM(revenue), 2) AS revenue,
    COUNT(DISTINCT transaction_id) AS orders
FROM coffee
GROUP BY order_quarter
ORDER BY order_quarter;

-- Query 26: Best and worst single day by revenue (peak vs trough)
WITH daily AS (
    SELECT transaction_date, SUM(revenue) AS revenue
    FROM coffee
    GROUP BY transaction_date
)

(SELECT transaction_date, revenue, 'Best Day' AS label FROM daily ORDER BY revenue DESC LIMIT 1)
UNION ALL
(SELECT transaction_date, revenue, 'Worst Day' AS label FROM daily ORDER BY revenue ASC LIMIT 1);


/* ----------------------------------------------------------------------------
   8. PRODUCT-DETAIL (SKU-LEVEL) & PRICING DEEP DIVE
   
   SKU = Stock Keeping Unit
   An SKU is a unique code or identifier used to identify a specific product or product variant.
   ---------------------------------------------------------------------------- */

-- Query 27: Top 10 individual products (product_detail) by revenue - most granular SKU view
SELECT product_category, product_type, product_detail,
       ROUND(SUM(revenue), 2) AS revenue,
       SUM(transaction_qty) AS qty_sold
FROM coffee
GROUP BY product_category, product_type, product_detail
ORDER BY revenue DESC
LIMIT 10;

-- Query 28: Price-tier analysis - bucket unit_price and see which tier drives revenue
SELECT
    CASE
        WHEN unit_price < 2  THEN 'Under $2'
        WHEN unit_price < 3  THEN '$2-$2.99'
        WHEN unit_price < 4  THEN '$3-$3.99'
        ELSE '$4+'
    END AS price_tier,
    COUNT(*) AS line_items,
    SUM(transaction_qty) AS qty_sold,
    ROUND(SUM(revenue), 2) AS revenue
FROM coffee
GROUP BY price_tier
ORDER BY revenue DESC;

ALTER TABLE coffee
ADD COLUMN  price_tier VARCHAR(20)
GENERATED ALWAYS AS (
    CASE
        WHEN unit_price < 2  THEN 'very_low'
        WHEN unit_price < 3  THEN 'low'
        WHEN unit_price < 4  THEN 'medium'
        ELSE 'high'
    END
) STORED
AFTER unit_price;

-- Query 29: Average unit price and revenue per unit by product_type (pricing sanity check)
SELECT
    product_type,
    ROUND(AVG(unit_price), 2) AS avg_unit_price,
    ROUND(SUM(revenue) / SUM(transaction_qty), 2) AS revenue_per_unit
FROM coffee
GROUP BY product_type
ORDER BY revenue_per_unit DESC;


/* ----------------------------------------------------------------------------
   9. DATA QUALITY / SANITY CHECKS
   ---------------------------------------------------------------------------- */

-- Query 30: Confirm transaction_id is unique per row
SELECT transaction_id, COUNT(*) AS row_count
FROM coffee
GROUP BY transaction_id
HAVING COUNT(*) > 1;

-- Query 31: Date coverage check - first/last date and any missing calendar days
SELECT
    MIN(transaction_date) AS first_date,
    MAX(transaction_date) AS last_date,
    DATEDIFF(MAX(transaction_date), MIN(transaction_date)) + 1 AS calendar_days_in_range,
    COUNT(DISTINCT transaction_date) AS days_with_sales
FROM coffee;


/* ----------------------------------------------------------------------------
   10. SUMMARY VIEW
   ---------------------------------------------------------------------------- */

CREATE VIEW coffee_sales AS
SELECT
    transaction_id,
    transaction_date,
    order_month,
    order_dow,
    order_hour,
    day_type,
    day_part,
    store_location,
    product_category,
    product_type,
    product_detail,
    order_size,
    price_tier,
    transaction_qty,
    unit_price,
    revenue
FROM coffee;

SELECT * FROM coffee_sales LIMIT 100;