/*====================================================
  CS401 - Essentials of SAS | Final Project
  Authors: Harun, Lumabi, Manuel, Uy
====================================================*/

ods exclude all;
ods graphics on;

/* STAGE 1: DATA INGESTION */
libname MYLIB "/home/u64511366/Essentials_SAS/SAS-Final-Project";

proc import datafile="/home/u64511366/Essentials_SAS/SAS-Final-Project/olist_orders_dataset.csv"
    out=MYLIB.orders_raw dbms=csv replace; guessingrows=max;
run;

proc import datafile="/home/u64511366/Essentials_SAS/SAS-Final-Project/olist_order_items_dataset.csv"
    out=MYLIB.items_raw dbms=csv replace; guessingrows=max;
run;

proc import datafile="/home/u64511366/Essentials_SAS/SAS-Final-Project/olist_customers_dataset.csv"
    out=MYLIB.customers_raw dbms=csv replace; guessingrows=max;
run;


/* STAGE 2: DATA CLEAN UP */
data MYLIB.customers_clean;
    set MYLIB.customers_raw;
    customer_city  = upcase(strip(customer_city));
    customer_state = upcase(strip(customer_state));
    customer_id_masked = cats(substr(customer_id,1,4), '**********', substr(customer_id,28,4));
    drop customer_unique_id customer_zip_code_prefix;
run;

data MYLIB.orders_clean;
    set MYLIB.orders_raw;
    order_status = upcase(strip(order_status));
    
    if missing(order_delivered_customer_date) then delivery_flag = "NOT DELIVERED";
    else delivery_flag = "DELIVERED";

    if delivery_flag = "DELIVERED" then
        delivery_days = round((order_delivered_customer_date - order_purchase_timestamp) / 86400, 1);
    else delivery_days = .;
    drop order_approved_at order_delivered_carrier_date order_estimated_delivery_date;
run;

data MYLIB.items_clean;
    set MYLIB.items_raw;
    if missing(price)         then price = 0;
    if missing(freight_value) then freight_value = 0;
    drop product_id seller_id shipping_limit_date;
run;


/* STAGE 3: DATA TRANSFORMATIONS */
proc sort data=MYLIB.orders_clean; by order_id; run;
proc sort data=MYLIB.items_clean; by order_id; run;
proc sort data=MYLIB.customers_clean; by customer_id; run;

data MYLIB.orders_items;
    merge MYLIB.orders_clean (in=a) MYLIB.items_clean (in=b);
    by order_id;
    if a and b;
run;

proc sort data=MYLIB.orders_items; by customer_id; run;

data MYLIB.full_data;
    merge MYLIB.orders_items (in=a) MYLIB.customers_clean (in=b);
    by customer_id;
    if a;
    drop customer_id;
run;

data MYLIB.delivered;
    set MYLIB.full_data;
    where delivery_flag = "DELIVERED";
run;


/* STAGE 4: CALCULATIONS */
data MYLIB.calculated;
    set MYLIB.delivered;

    total_value = price + freight_value;

    if total_value > 0 then freight_pct = round((freight_value / total_value) * 100, 0.01);
    else freight_pct = 0;

    /* Order Tier Definition */
    if      total_value <  50 then order_tier = "SMALL";
    else if total_value < 200 then order_tier = "MEDIUM";
    else                           order_tier = "LARGE";

    /* Revenue Growth Projection */
    array proj{3} proj_q1 proj_q2 proj_q3;
    do i = 1 to 3;
        proj{i} = round(total_value * (1.05 ** i), 0.01);
    end;
    drop i;

    /* Customer Value Score & Grouping */
    if total_value > 0 then customer_value_score = round((total_value - freight_value) / total_value * 100, 0.1);
    else customer_value_score = 0;

    if      customer_value_score >= 80 then customer_value_group = "HIGH VALUE";
    else if customer_value_score >= 50 then customer_value_group = "MID VALUE";
    else                                    customer_value_group = "LOW VALUE";

    /* Delivery Performance Grouping */
    if      delivery_days <= 3  then delivery_performance = "EXCELLENT";
    else if delivery_days <= 7  then delivery_performance = "GOOD";
    else if delivery_days <= 14 then delivery_performance = "POOR";
    else if delivery_days >  14 then delivery_performance = "CRITICAL";
    else                             delivery_performance = "UNTRACKED";

    /* Freight Burden Grouping */
    if      freight_pct <  15 then freight_burden = "LOW FREIGHT";
    else if freight_pct <  35 then freight_burden = "MODERATE";
    else if freight_pct >= 35 then freight_burden = "HIGH FREIGHT";
    else                           freight_burden = "UNKNOWN";
run;


/* STAGE 5: SAS TECHNIQUES & MACROS */
proc format library=MYLIB;
    value speedfmt
        low -  3 = "FAST (1-3 days)"
        4   -  7 = "STANDARD (4-7 days)"
        8   - 14 = "SLOW (8-14 days)"
        15  - high = "VERY SLOW (15+ days)";
run;

options fmtsearch=(MYLIB work);

data MYLIB.calculated;
    set MYLIB.calculated;
    format delivery_days speedfmt.;
run;

%macro summarize(min_value=200, state=ALL);

    data MYLIB.final_data;
        set MYLIB.calculated;
        %if &state = ALL %then %do;
            where total_value >= &min_value;
        %end;
        %else %do;
            where total_value >= &min_value and customer_state = upcase("&state");
        %end;
    run;

    ods exclude none;

    proc means data=MYLIB.final_data n mean median sum min max maxdec=2;
        class delivery_days;
        var total_value freight_pct;
        title "Summary of Order Value and Freight by Delivery Speed";
    run;

    proc freq data=MYLIB.final_data order=freq;
        tables customer_state / nocum;
        title "Number of Orders by Customer State";
    run;

    proc freq data=MYLIB.final_data;
        tables delivery_days * order_tier / norow nocol nocum;
        title "Delivery Speed vs Order Size";
    run;
    
    proc freq data=MYLIB.final_data order=freq;
        tables customer_value_group / nocum;
        title "Customer Value Group Distribution";
    run;

    proc freq data=MYLIB.final_data order=freq;
        tables delivery_performance / nocum;
        title "Delivery Performance Breakdown";
    run;

    proc freq data=MYLIB.final_data order=freq;
        tables freight_burden / nocum;
        title "Freight Burden Classification";
    run;

    /* STAGE 6: INSIGHTS & VISUALIZATIONS */
    proc sgplot data=MYLIB.final_data;
        histogram delivery_days / fillattrs=(color=steelblue) binwidth=1;
        refline 7 / axis=x lineattrs=(color=red pattern=dash) label="7-day mark";
        xaxis label="Delivery Days";
        yaxis label="Number of Orders";
        title "Insight 1: Delivery Time Distribution";
    run;

    proc sgplot data=MYLIB.final_data;
        scatter x=freight_value y=price / markerattrs=(color=gray size=3) transparency=0.6;
        reg     x=freight_value y=price / lineattrs=(color=red thickness=2);
        xaxis label="Freight Value (BRL)" max=150;
        yaxis label="Product Price (BRL)"  max=2000;
        title "Insight 2: Price vs Freight Value";
    run;

    proc sgplot data=MYLIB.final_data;
        vbar customer_state / response=total_value stat=sum fillattrs=(color=teal) categoryorder=respdesc;
        xaxis label="Customer State";
        yaxis label="Total Revenue (BRL)";
        title "Insight 3: Total Revenue by Customer State";
    run;
    
    /* Updated Bonus Insight Chart */
    proc sgplot data=MYLIB.final_data;
        vbar order_tier / stat=pct fillattrs=(color=goldenrod) categoryorder=respdesc;
        xaxis label="Order Size Tier";
        yaxis label="Percentage of Total Volume (%)";
        title "Bonus Insight: Two-Thirds of Orders Fall in the Mid-Value Tier";
    run;

    ods exclude all;
%mend summarize;

%summarize(min_value=0, state=ALL);
ods graphics off;


/* EXPORT SAVED OUTPUTS */
options dlcreatedir;
libname OUTDIR "/home/u64511366/Essentials_SAS/SAS-Final-Project/saved_outputs";

proc export data=MYLIB.final_data
    outfile="/home/u64511366/Essentials_SAS/SAS-Final-Project/saved_outputs/final_data_summary.csv"
    dbms=csv replace;
run;

proc means data=MYLIB.final_data n mean median sum min max maxdec=2 noprint;
    class delivery_days;
    var total_value freight_pct;
    output out=MYLIB.means_output mean=mean_value mean_freight n=order_count;
run;

proc export data=MYLIB.means_output
    outfile="/home/u64511366/Essentials_SAS/SAS-Final-Project/saved_outputs/means_output.csv"
    dbms=csv replace;
run;

ods graphics on / outputfmt=png width=900px imagename="insight1_delivery";
ods listing gpath="/home/u64511366/Essentials_SAS/SAS-Final-Project/saved_outputs/";

proc sgplot data=MYLIB.final_data;
    histogram delivery_days / fillattrs=(color=steelblue) binwidth=1;
    refline 7 / axis=x lineattrs=(color=red pattern=dash) label="7-day mark";
    xaxis label="Delivery Days";
    yaxis label="Number of Orders";
    title "Insight 1: Delivery Time Distribution";
run;

ods graphics / imagename="insight2_price_vs_freight";
proc sgplot data=MYLIB.final_data;
    scatter x=freight_value y=price / markerattrs=(color=gray size=3) transparency=0.6;
    reg     x=freight_value y=price / lineattrs=(color=red thickness=2);
    xaxis label="Freight Value (BRL)" max=150;
    yaxis label="Product Price (BRL)"  max=2000;
    title "Insight 2: Price vs Freight Value";
run;

ods graphics / imagename="insight3_revenue_by_state";
proc sgplot data=MYLIB.final_data;
    vbar customer_state / response=total_value stat=sum fillattrs=(color=teal) categoryorder=respdesc;
    xaxis label="Customer State";
    yaxis label="Total Revenue (BRL)";
    title "Insight 3: Total Revenue by Customer State";
  run;

ods listing close;
ods graphics off;
