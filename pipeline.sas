/*=====================================================================
  ECOMMERCE DATA PIPELINE - OLIST BRAZILIAN E-COMMERCE DATASET
  Author: [Team Name] | CS401 Essentials of SAS - Final Project
=====================================================================*/

/* 1: DATA INGESTION */
/* ========================================================== */

/* 1. Define the Library */
LIBNAME MYLIB "/home/u64511366/Essentials_SAS/SAS-Final-Project"; 

/* 2. Import Orders */
PROC IMPORT datafile="/home/u64511366/Essentials_SAS/SAS-Final-Project/olist_orders_dataset.csv"
    out=MYLIB.orders_raw 
    dbms=csv 
    replace;
    guessingrows=max;
RUN;

/* 3. Import Items */
PROC IMPORT datafile="/home/u64511366/Essentials_SAS/SAS-Final-Project/olist_order_items_dataset.csv"
    out=MYLIB.items_raw 
    dbms=csv 
    replace;
    guessingrows=max;
RUN;

/* 4. Import Customers */
PROC IMPORT datafile="/home/u64511366/Essentials_SAS/SAS-Final-Project/olist_customers_dataset.csv"
    out=MYLIB.customers_raw 
    dbms=csv 
    replace;
    guessingrows=max;
RUN;


/*=====================================================================
  STAGE 2: DATA CLEAN UP
=====================================================================*/

/* --- Clean customers: casing, spacing, masking sensitive ID --- */
data MYLIB.customers_clean;
    set MYLIB.customers_raw;

    /* Standardize casing/spacing on city and state */
    customer_city  = upcase(strip(customer_city));
    customer_state = upcase(strip(customer_state));

    /* Privacy compliance: mask the raw customer_id, drop the unhashed key */
    length customer_id_masked $20.;
    customer_id_masked = cats(substr(customer_id,1,4), repeat('*',9), substr(customer_id,length(customer_id)-2,3));

    drop customer_id; /* drop raw unhashed identifier */
    rename customer_id_masked = customer_id_masked;
run;

/* --- Clean orders: handle missing timestamps with descriptive flag --- */
data MYLIB.orders_clean;
    set MYLIB.orders_raw;

    order_status = upcase(strip(order_status));

    /* Missing value management: flag undelivered orders instead of leaving blank dates */
    length delivery_flag $20.;
    if missing(order_delivered_customer_date) then delivery_flag = "NOT DELIVERED";
    else delivery_flag = "DELIVERED";

    /* Compute delivery days only when both dates exist (avoids errors) */
    if not missing(order_delivered_customer_date) and not missing(order_purchase_timestamp) then
        delivery_days = order_delivered_customer_date - order_purchase_timestamp;
    else delivery_days = .; /* missing numeric left as . rather than 0, flagged separately */
run;

/* --- Clean order items: replace missing numeric values with 0 --- */
data MYLIB.items_clean;
    set MYLIB.items_raw;

    if missing(price) then price = 0;
    if missing(freight_value) then freight_value = 0;
run;


/*=====================================================================
  STAGE 3: DATA TRANSFORMATIONS
=====================================================================*/

/* Relational sorting before merge (O(N log N)) */
proc sort data=MYLIB.orders_clean;    by order_id;    run;
proc sort data=MYLIB.items_clean;     by order_id;    run;
proc sort data=MYLIB.customers_clean; by customer_id; run;

/* Step 1: merge orders with their line items (inner join via IN=) */
data MYLIB.orders_items_merged;
    merge MYLIB.orders_clean(in=a) MYLIB.items_clean(in=b);
    by order_id;
    if a and b; /* inner join: only orders that have matching items */
run;

/* Need customer_id sorted on the merged set to join to customers */
proc sort data=MYLIB.orders_items_merged; by customer_id; run;

/* Step 2: merge in customer info (left join, keep all orders even if customer missing) */
data MYLIB.full_merged;
    merge MYLIB.orders_items_merged(in=a) MYLIB.customers_clean(in=b);
    by customer_id;
    if a; /* left join: keep all order/item records */
run;

/* Subsetting: focus on delivered orders only for clean insight reporting */
data MYLIB.subset_delivered;
    set MYLIB.full_merged;
    where delivery_flag = "DELIVERED";
run;


/*=====================================================================
  STAGE 4: CALCULATIONS
=====================================================================*/

data MYLIB.calculated;
    set MYLIB.subset_delivered;

    /* Standard arithmetic: total order value per line item */
    total_value = price + freight_value;

    /* Compounding calc: freight as a % of total value */
    if total_value > 0 then freight_pct = round((freight_value / total_value) * 100, 0.01);
    else freight_pct = 0;

    /* Array-based example: simulate a 3-period markup projection (5%/quarter) */
    array proj{3} proj_q1 proj_q2 proj_q3;
    do i = 1 to 3;
        proj{i} = total_value * (1.05 ** i);
    end;
    drop i;
run;


/*=====================================================================
  STAGE 5: APPLYING SAS TECHNIQUES (3 techniques used below)
=====================================================================*/

/* Technique 1: PROC FORMAT - custom delivery speed bins */
proc format library=MYLIB;
    value delivspeedfmt
        low - 3   = "FAST (<=3 days)"
        4  - 7    = "STANDARD (4-7 days)"
        8  - high = "SLOW (8+ days)";
run;

data MYLIB.calculated;
    set MYLIB.calculated;
    format delivery_days delivspeedfmt.;
run;

/* Technique 2: Macro automation - parameterized for the live "Parameter Swap" demo */
%macro run_pipeline(min_value=0, state=ALL);

    data MYLIB.final_filtered;
        set MYLIB.calculated;
        %if &state ne ALL %then %do;
            where total_value >= &min_value and customer_state = "&state";
        %end;
        %else %do;
            where total_value >= &min_value;
        %end;
    run;

    /* Technique 3: PROC MEANS / PROC FREQ - summarization */
    proc means data=MYLIB.final_filtered n mean sum min max;
        class delivery_days;
        var total_value freight_pct;
        title "Order Value Summary by Delivery Speed (min_value=&min_value, state=&state)";
    run;

    proc freq data=MYLIB.final_filtered;
        tables customer_state delivery_days / nocum;
        title "Distribution of Orders by State and Delivery Speed";
    run;

%mend run_pipeline;

/* Default run - swap parameters live on request during presentation */
%run_pipeline(min_value=0, state=ALL);

/* Example of the "Parameter Swap" demo: filter to a specific state and minimum order value */
/* %run_pipeline(min_value=100, state=SP); */


/*=====================================================================
  STAGE 6: RESULTS & INSIGHTS (visual representation)
=====================================================================*/

ods graphics on;

proc sgplot data=MYLIB.final_filtered;
    histogram delivery_days;
    title "Distribution of Delivery Times (Days)";
run;

proc sgplot data=MYLIB.final_filtered;
    scatter x=freight_value y=price;
    reg x=freight_value y=price;
    title "Price vs. Freight Value with Fit Line";
run;

proc sgplot data=MYLIB.final_filtered;
    vbar customer_state / response=total_value stat=sum;
    title "Total Order Value by Customer State";
run;

ods graphics off;

