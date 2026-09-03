-- Source validation queries for Retail Fulfillment Control Tower
-- Co-authored with CoCo

-- Verify ORDER_FACT row count
SELECT 'ORDER_FACT' AS table_name, COUNT(*) AS row_count FROM DEMO_DB.DEMO.ORDER_FACT;

-- Verify STORE_DIM row count
SELECT 'STORE_DIM' AS table_name, COUNT(*) AS row_count FROM DEMO_DB.DEMO.STORE_DIM;

-- Verify PRODUCT_DIM row count
SELECT 'PRODUCT_DIM' AS table_name, COUNT(*) AS row_count FROM DEMO_DB.DEMO.PRODUCT_DIM;

-- Verify DATE_DIM row count
SELECT 'DATE_DIM' AS table_name, COUNT(*) AS row_count FROM DEMO_DB.DEMO.DATE_DIM;

-- Verify join integrity (no orphan keys)
SELECT 'orphan_store_keys' AS check_name, COUNT(*) AS cnt
FROM DEMO_DB.DEMO.ORDER_FACT o
LEFT JOIN DEMO_DB.DEMO.STORE_DIM s ON o.ORDER_STORE_KEY = s.STORE_KEY
WHERE s.STORE_KEY IS NULL;

SELECT 'orphan_product_keys' AS check_name, COUNT(*) AS cnt
FROM DEMO_DB.DEMO.ORDER_FACT o
LEFT JOIN DEMO_DB.DEMO.PRODUCT_DIM p ON o.PRODUCT_KEY = p.PRODUCT_KEY
WHERE p.PRODUCT_KEY IS NULL;

SELECT 'orphan_date_keys' AS check_name, COUNT(*) AS cnt
FROM DEMO_DB.DEMO.ORDER_FACT o
LEFT JOIN DEMO_DB.DEMO.DATE_DIM d ON o.ORDER_DATE_KEY = d.DATE_KEY
WHERE d.DATE_KEY IS NULL;

-- Check distinct values for filter dimensions
SELECT 'regions' AS dim, COUNT(DISTINCT REGION) AS distinct_cnt FROM DEMO_DB.DEMO.STORE_DIM;
SELECT 'categories' AS dim, COUNT(DISTINCT CATEGORY) AS distinct_cnt FROM DEMO_DB.DEMO.PRODUCT_DIM;
SELECT 'channels' AS dim, COUNT(DISTINCT ORDER_CHANNEL) AS distinct_cnt FROM DEMO_DB.DEMO.ORDER_FACT;
SELECT 'statuses' AS dim, COUNT(DISTINCT ORDER_STATUS) AS distinct_cnt FROM DEMO_DB.DEMO.ORDER_FACT;

-- Sample date range
SELECT MIN(d.FULL_DATE) AS min_date, MAX(d.FULL_DATE) AS max_date
FROM DEMO_DB.DEMO.ORDER_FACT o
JOIN DEMO_DB.DEMO.DATE_DIM d ON o.ORDER_DATE_KEY = d.DATE_KEY;
