-- Static SQL query for retail fulfillment and returns data
-- Co-authored with CoCo
SELECT
    o.ORDER_ID                          AS order_id,
    d.FULL_DATE                         AS order_date,
    s.REGION                            AS region,
    s.STORE_NAME                        AS store_name,
    p.CATEGORY                          AS category,
    p.SUBCATEGORY                       AS subcategory,
    o.ORDER_CHANNEL                     AS order_channel,
    o.SHIP_METHOD                       AS ship_method,
    o.ORDER_STATUS                      AS order_status,
    o.QUANTITY_ORDERED                  AS quantity_ordered,
    o.QUANTITY_RETURNED                 AS quantity_returned,
    o.NET_REVENUE                       AS net_revenue,
    o.NET_PROFIT                        AS net_profit,
    o.SHIPPING_AMOUNT                   AS shipping_amount,
    o.IS_RETURNED                       AS is_returned,
    o.IS_CANCELLED                      AS is_cancelled,
    o.DAYS_TO_SHIP                      AS days_to_ship
FROM DEMO_DB.DEMO.ORDER_FACT o
JOIN DEMO_DB.DEMO.STORE_DIM s
    ON o.ORDER_STORE_KEY = s.STORE_KEY
JOIN DEMO_DB.DEMO.PRODUCT_DIM p
    ON o.PRODUCT_KEY = p.PRODUCT_KEY
JOIN DEMO_DB.DEMO.DATE_DIM d
    ON o.ORDER_DATE_KEY = d.DATE_KEY
