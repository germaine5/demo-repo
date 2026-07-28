#!/usr/bin/env bash
# =============================================================================
# find_qs_dashboard_copies.sh
#
# Finds who performed "Save As" on a specific QuickSight dashboard and
# whether they subsequently published a new dashboard from that analysis.
#
# APPROACH (hybrid):
#   - QuickSight API  → resolves dashboard ID to name, finds cloned analyses
#                       and published dashboards by name matching
#   - CloudTrail      → provides user attribution (who + when) for
#                       CreateAnalysis and CreateDashboard events
#   - Correlation     → matches CloudTrail events to QuickSight resources
#                       by username + timestamp proximity
#
# USAGE:
#   chmod +x find_qs_dashboard_copies.sh
#   ./find_qs_dashboard_copies.sh
# =============================================================================

# -------------------------------------------------------------------------
# CONFIGURE THESE VALUES
# -------------------------------------------------------------------------
TARGET_DASHBOARD_ID="6xxxxxxxxxxxxxx"
REGION="us-east-1"
# -------------------------------------------------------------------------

set -euo pipefail

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
if [ -z "$ACCOUNT_ID" ]; then
    echo "ERROR: Could not determine AWS Account ID. Check your credentials." >&2
    exit 1
fi

echo "================================================================"
echo "  QuickSight 'Save As' Activity Report (CloudTrail + QS API)"
echo "  Account : $ACCOUNT_ID"
echo "  Region  : $REGION"
echo "  Target  : $TARGET_DASHBOARD_ID"
echo "================================================================"
echo ""

# =============================================================================
# PART 1: QuickSight API — resolve name, find cloned analyses + dashboards
# =============================================================================

# -----------------------------------------------------------------------------
# Step 1: Get the target dashboard name
# -----------------------------------------------------------------------------
echo "Step 1: Resolving dashboard name from QuickSight API..."

TARGET_DASH_JSON=$(aws quicksight describe-dashboard \
    --aws-account-id "$ACCOUNT_ID" \
    --dashboard-id "$TARGET_DASHBOARD_ID" \
    --region "$REGION" \
    --output json 2>&1) || {
    echo "ERROR: Could not describe dashboard '$TARGET_DASHBOARD_ID'."
    echo "       Verify the ID and quicksight:DescribeDashboard permission."
    exit 1
}

TARGET_DASH_NAME=$(echo "$TARGET_DASH_JSON" | jq -r '.Dashboard.Name')
TARGET_DASH_CREATED=$(echo "$TARGET_DASH_JSON" | jq -r '.Dashboard.CreatedTime')
echo "  ✅ \"$TARGET_DASH_NAME\" (created: $TARGET_DASH_CREATED)"
echo ""

# -----------------------------------------------------------------------------
# Step 2: List ALL analyses — find ones matching the dashboard name
# (QuickSight "Save As" gives the new analysis the same name as the dashboard)
# -----------------------------------------------------------------------------
echo "Step 2: Listing all QuickSight analyses to find clones..."

ALL_ANALYSES="[]"
NEXT_TOKEN=""
while true; do
    if [ -z "$NEXT_TOKEN" ]; then
        PAGE=$(aws quicksight list-analyses \
            --aws-account-id "$ACCOUNT_ID" \
            --region "$REGION" \
            --output json)
    else
        PAGE=$(aws quicksight list-analyses \
            --aws-account-id "$ACCOUNT_ID" \
            --region "$REGION" \
            --next-token "$NEXT_TOKEN" \
            --output json)
    fi
    ALL_ANALYSES=$(echo "$ALL_ANALYSES $PAGE" | jq -s '.[0] + [.[1].AnalysisSummaryList[]?]')
    NEXT_TOKEN=$(echo "$PAGE" | jq -r '.NextToken // empty')
    [ -z "$NEXT_TOKEN" ] && break
done

CLONED_ANALYSES=$(echo "$ALL_ANALYSES" | jq -c \
    --arg name "$TARGET_DASH_NAME" \
    '[.[] | select(.Name | ascii_downcase | contains($name | ascii_downcase))]')
CLONE_COUNT=$(echo "$CLONED_ANALYSES" | jq 'length')
echo "  Found $CLONE_COUNT analysis/analyses matching \"$TARGET_DASH_NAME\"."
echo ""

# -----------------------------------------------------------------------------
# Step 3: List ALL dashboards — find ones that were published from those analyses
# -----------------------------------------------------------------------------
echo "Step 3: Listing all QuickSight dashboards to find published copies..."

ALL_DASHBOARDS="[]"
NEXT_TOKEN=""
while true; do
    if [ -z "$NEXT_TOKEN" ]; then
        PAGE=$(aws quicksight list-dashboards \
            --aws-account-id "$ACCOUNT_ID" \
            --region "$REGION" \
            --output json)
    else
        PAGE=$(aws quicksight list-dashboards \
            --aws-account-id "$ACCOUNT_ID" \
            --region "$REGION" \
            --next-token "$NEXT_TOKEN" \
            --output json)
    fi
    ALL_DASHBOARDS=$(echo "$ALL_DASHBOARDS $PAGE" | jq -s '.[0] + [.[1].DashboardSummaryList[]?]')
    NEXT_TOKEN=$(echo "$PAGE" | jq -r '.NextToken // empty')
    [ -z "$NEXT_TOKEN" ] && break
done

# Dashboards matching the name but NOT the original target
PUBLISHED_COPIES=$(echo "$ALL_DASHBOARDS" | jq -c \
    --arg name "$TARGET_DASH_NAME" \
    --arg orig "$TARGET_DASHBOARD_ID" \
    '[.[] | select(
        (.Name | ascii_downcase | contains($name | ascii_downcase)) and
        .DashboardId != $orig
    )]')
PUB_COUNT=$(echo "$PUBLISHED_COPIES" | jq 'length')
echo "  Found $PUB_COUNT published dashboard copy/copies."
echo ""

# =============================================================================
# PART 2: CloudTrail — get user attribution for CreateAnalysis + CreateDashboard
# =============================================================================

# Helper: paginate all CloudTrail lookup-events for a given event name
paginate_cloudtrail() {
    local event_name=$1
    local all_events="[]"
    local next_token=""
    while true; do
        if [ -z "$next_token" ]; then
            response=$(aws cloudtrail lookup-events \
                --lookup-attributes AttributeKey=EventName,AttributeValue="$event_name" \
                --region "$REGION" \
                --max-results 50 \
                --output json)
        else
            response=$(aws cloudtrail lookup-events \
                --lookup-attributes AttributeKey=EventName,AttributeValue="$event_name" \
                --region "$REGION" \
                --max-results 50 \
                --next-token "$next_token" \
                --output json)
        fi
        all_events=$(echo "$all_events $response" | jq -s '.[0] + [.[1].Events[]?]')
        next_token=$(echo "$response" | jq -r '.NextToken // empty')
        [ -z "$next_token" ] && break
    done
    echo "$all_events"
}

echo "Step 4: Fetching CloudTrail CreateAnalysis events for user attribution..."
CT_ANALYSIS_EVENTS=$(paginate_cloudtrail "CreateAnalysis")
CT_ANALYSIS_COUNT=$(echo "$CT_ANALYSIS_EVENTS" | jq 'length')
echo "  Found $CT_ANALYSIS_COUNT total CreateAnalysis event(s) in CloudTrail."

echo "Step 5: Fetching CloudTrail CreateDashboard events for user attribution..."
CT_DASHBOARD_EVENTS=$(paginate_cloudtrail "CreateDashboard")
CT_DASHBOARD_COUNT=$(echo "$CT_DASHBOARD_EVENTS" | jq 'length')
echo "  Found $CT_DASHBOARD_COUNT total CreateDashboard event(s) in CloudTrail."
echo ""

# =============================================================================
# PART 3: Correlate — match QS resources to CloudTrail events by timestamp
# =============================================================================
# Strategy: for each cloned analysis (from QS API), find the CloudTrail
# CreateAnalysis event whose timestamp is closest to the analysis CreatedTime.
# Then check if that same user also has a CreateDashboard event after that time
# that matches one of the published dashboard copies.
# =============================================================================

echo "================================================================"
echo "  RESULTS"
echo "================================================================"

if [ "$CLONE_COUNT" -eq 0 ]; then
    echo ""
    echo "  No analyses found matching \"$TARGET_DASH_NAME\"."
    echo "  Either no one has done 'Save As', or the analysis was renamed."
    echo ""
    echo "  All CreateAnalysis events in CloudTrail (last 90 days):"
    echo "----------------------------------------------------------------"
    echo "$CT_ANALYSIS_EVENTS" | jq -c '.[]' | while read -r event; do
        RAW=$(echo "$event" | jq -r '.CloudTrailEvent | fromjson')
        echo "  👤 $(echo "$RAW" | jq -r '.userIdentity.arn // .userIdentity.principalId // "unknown"')"
        echo "     Time: $(echo "$RAW" | jq -r '.eventTime')"
        echo "----------------------------------------------------------------"
    done
    exit 0
fi

echo "$CLONED_ANALYSES" | jq -c '.[]' | while read -r analysis; do
    ANALYSIS_ID=$(echo "$analysis"      | jq -r '.AnalysisId')
    ANALYSIS_NAME=$(echo "$analysis"    | jq -r '.Name')
    ANALYSIS_CREATED=$(echo "$analysis" | jq -r '.CreatedTime')
    ANALYSIS_STATUS=$(echo "$analysis"  | jq -r '.Status')

    echo ""
    echo "📊 Cloned Analysis: \"$ANALYSIS_NAME\""
    echo "   Analysis ID : $ANALYSIS_ID"
    echo "   Created     : $ANALYSIS_CREATED"
    echo "   Status      : $ANALYSIS_STATUS"

    # Convert analysis created time to epoch for comparison
    ANALYSIS_EPOCH=$(date -d "$ANALYSIS_CREATED" +%s 2>/dev/null || \
                     date -j -f "%Y-%m-%dT%H:%M:%S%z" "$ANALYSIS_CREATED" +%s 2>/dev/null || echo "0")

    # Find the CloudTrail CreateAnalysis event closest in time to this analysis
    MATCHED_CT=$(echo "$CT_ANALYSIS_EVENTS" | jq -c \
        --argjson epoch "$ANALYSIS_EPOCH" \
        '[.[] | .CloudTrailEvent | fromjson |
          { userName: (.userIdentity.userName // "N/A"),
            userArn:  (.userIdentity.arn // "N/A"),
            eventTime: .eventTime,
            sourceIP: (.sourceIPAddress // "unknown"),
            epochDiff: ((.eventTime | sub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) - $epoch | fabs | floor)
          }
        ] | sort_by(.epochDiff) | .[0]' 2>/dev/null || echo "null")

    if [ "$MATCHED_CT" != "null" ] && [ -n "$MATCHED_CT" ]; then
        CT_USERNAME=$(echo "$MATCHED_CT" | jq -r '.userName')
        CT_ARN=$(echo "$MATCHED_CT"      | jq -r '.userArn')
        CT_TIME=$(echo "$MATCHED_CT"     | jq -r '.eventTime')
        CT_IP=$(echo "$MATCHED_CT"       | jq -r '.sourceIP')
        CT_DIFF=$(echo "$MATCHED_CT"     | jq -r '.epochDiff')
        echo ""
        echo "   🔎 CloudTrail match (closest CreateAnalysis event):"
        echo "      👤 UserName  : $CT_USERNAME"
        echo "      🔑 User ARN  : $CT_ARN"
        echo "      ⏱  Event Time: $CT_TIME"
        echo "      🌐 Source IP : $CT_IP"
        echo "      ⏳ Time diff : ${CT_DIFF}s from analysis creation"
    else
        CT_USERNAME="unknown"
        echo "   ⚠️  No matching CloudTrail event found for this analysis."
    fi

    # Check if this analysis was published as a dashboard
    MATCHED_DASH=$(echo "$PUBLISHED_COPIES" | jq -c \
        --arg name "$ANALYSIS_NAME" \
        '[.[] | select(.Name | ascii_downcase | contains($name | ascii_downcase))] | .[0]' 2>/dev/null || echo "null")

    echo ""
    if [ "$MATCHED_DASH" != "null" ] && [ -n "$MATCHED_DASH" ] && [ "$MATCHED_DASH" != "[]" ]; then
        DASH_ID=$(echo "$MATCHED_DASH"      | jq -r '.DashboardId')
        DASH_NAME=$(echo "$MATCHED_DASH"    | jq -r '.Name')
        DASH_CREATED=$(echo "$MATCHED_DASH" | jq -r '.CreatedTime')
        DASH_UPDATED=$(echo "$MATCHED_DASH" | jq -r '.LastUpdatedTime')

        echo "   🟢 PUBLISHED as a new dashboard:"
        echo "      Dashboard ID  : $DASH_ID"
        echo "      Name          : $DASH_NAME"
        echo "      Created       : $DASH_CREATED"
        echo "      Last Updated  : $DASH_UPDATED"

        # Find CloudTrail attribution for the publish event
        DASH_EPOCH=$(date -d "$DASH_CREATED" +%s 2>/dev/null || \
                     date -j -f "%Y-%m-%dT%H:%M:%S%z" "$DASH_CREATED" +%s 2>/dev/null || echo "0")

        MATCHED_DASH_CT=$(echo "$CT_DASHBOARD_EVENTS" | jq -c \
            --argjson epoch "$DASH_EPOCH" \
            '[.[] | .CloudTrailEvent | fromjson |
              { userName: (.userIdentity.userName // "N/A"),
                userArn:  (.userIdentity.arn // "N/A"),
                eventTime: .eventTime,
                sourceIP: (.sourceIPAddress // "unknown"),
                epochDiff: ((.eventTime | sub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) - $epoch | fabs | floor)
              }
            ] | sort_by(.epochDiff) | .[0]' 2>/dev/null || echo "null")

        if [ "$MATCHED_DASH_CT" != "null" ] && [ -n "$MATCHED_DASH_CT" ]; then
            PUB_USERNAME=$(echo "$MATCHED_DASH_CT" | jq -r '.userName')
            PUB_ARN=$(echo "$MATCHED_DASH_CT"      | jq -r '.userArn')
            PUB_TIME=$(echo "$MATCHED_DASH_CT"     | jq -r '.eventTime')
            PUB_IP=$(echo "$MATCHED_DASH_CT"       | jq -r '.sourceIP')
            PUB_DIFF=$(echo "$MATCHED_DASH_CT"     | jq -r '.epochDiff')
            echo ""
            echo "      🔎 CloudTrail match (closest CreateDashboard event):"
            echo "         👤 UserName  : $PUB_USERNAME"
            echo "         🔑 User ARN  : $PUB_ARN"
            echo "         ⏱  Event Time: $PUB_TIME"
            echo "         🌐 Source IP : $PUB_IP"
            echo "         ⏳ Time diff : ${PUB_DIFF}s from dashboard creation"
        fi
    else
        echo "   🟡 NOT yet published as a dashboard (analysis only)."
    fi

    echo ""
    echo "----------------------------------------------------------------"
done

echo ""
echo "================================================================"
echo "  SUMMARY"
echo "================================================================"
echo "  Source dashboard : \"$TARGET_DASH_NAME\" ($TARGET_DASHBOARD_ID)"
echo "  Cloned analyses  : $CLONE_COUNT"
echo "  Published copies : $PUB_COUNT"
echo "================================================================"
