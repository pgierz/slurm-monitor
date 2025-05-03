from datetime import datetime, timedelta

import duckdb
import plotly.express as px
import streamlit as st

# Set page configuration
st.set_page_config(
    page_title="SLURM Cluster Monitoring Dashboard",
    page_icon="📊",
    layout="wide",
)


# Connect to the DuckDB database
@st.cache_resource
def get_connection():
    return duckdb.connect(".dlt/duckdb.db")


conn = get_connection()

# Title and description
st.title("SLURM Cluster Monitoring Dashboard")
st.markdown(
    """
This dashboard displays real-time information about your SLURM cluster, including:
- Node usage statistics
- Job distribution across partitions
- Resource utilization trends
"""
)

# Sidebar for filters
st.sidebar.header("Filters")

# Check if we have data in the database
try:
    # Get available time range from jobs table
    time_query = """
    SELECT
        MIN(submit_time) as min_time,
        MAX(submit_time) as max_time
    FROM slurm_data.jobs
    """
    time_range = conn.execute(time_query).fetchone()

    if time_range and time_range[0] and time_range[1]:
        min_date = datetime.fromtimestamp(time_range[0])
        max_date = datetime.fromtimestamp(time_range[1])

        # Date range selector
        date_range = st.sidebar.date_input(
            "Date Range",
            value=(max_date - timedelta(days=7), max_date),
            min_value=min_date,
            max_value=max_date,
        )

        # If we have a valid date range, use it for filtering
        if len(date_range) == 2:
            start_date, end_date = date_range
            start_timestamp = int(
                datetime.combine(start_date, datetime.min.time()).timestamp()
            )
            end_timestamp = int(
                datetime.combine(end_date, datetime.max.time()).timestamp()
            )

            # Get partitions for filtering
            partitions_query = (
                "SELECT DISTINCT name FROM slurm_data.partitions ORDER BY name"
            )
            partitions = [row[0] for row in conn.execute(partitions_query).fetchall()]

            selected_partitions = st.sidebar.multiselect(
                "Partitions", options=partitions, default=partitions
            )

            # Main dashboard content
            st.header("Cluster Overview")

            # Create a layout with columns
            col1, col2 = st.columns(2)

            with col1:
                # Node status summary
                st.subheader("Node Status")

                nodes_query = """
                SELECT
                    state,
                    COUNT(*) as count
                FROM slurm_data.nodes
                GROUP BY state
                """

                nodes_df = conn.execute(nodes_query).df()

                if not nodes_df.empty:
                    # Create a pie chart for node states
                    fig = px.pie(
                        nodes_df,
                        values="count",
                        names="state",
                        title="Node States Distribution",
                        color_discrete_sequence=px.colors.qualitative.Safe,
                    )
                    st.plotly_chart(fig, use_container_width=True)
                else:
                    st.info("No node data available")

            with col2:
                # Job status summary
                st.subheader("Job Status")

                jobs_query = f"""
                SELECT
                    job_state,
                    COUNT(*) as count
                FROM slurm_data.jobs
                WHERE submit_time BETWEEN {start_timestamp} AND {end_timestamp}
                {f"AND partition IN ({', '.join(['?' for _ in selected_partitions])})" if selected_partitions else ""}
                GROUP BY job_state
                """

                jobs_df = conn.execute(
                    jobs_query, selected_partitions if selected_partitions else []
                ).df()

                if not jobs_df.empty:
                    # Create a pie chart for job states
                    fig = px.pie(
                        jobs_df,
                        values="count",
                        names="job_state",
                        title="Job States Distribution",
                        color_discrete_sequence=px.colors.qualitative.Vivid,
                    )
                    st.plotly_chart(fig, use_container_width=True)
                else:
                    st.info("No job data available for the selected filters")

            # Resource utilization section
            st.header("Resource Utilization")

            # CPU and memory usage by partition
            partition_usage_query = f"""
            SELECT
                partition,
                COUNT(*) as job_count,
                SUM(num_cpus) as total_cpus,
                AVG(num_cpus) as avg_cpus_per_job
            FROM slurm_data.jobs
            WHERE submit_time BETWEEN {start_timestamp} AND {end_timestamp}
            {f"AND partition IN ({', '.join(['?' for _ in selected_partitions])})" if selected_partitions else ""}
            GROUP BY partition
            ORDER BY total_cpus DESC
            """

            partition_usage_df = conn.execute(
                partition_usage_query,
                selected_partitions if selected_partitions else [],
            ).df()

            if not partition_usage_df.empty:
                # Bar chart for CPU usage by partition
                fig = px.bar(
                    partition_usage_df,
                    x="partition",
                    y="total_cpus",
                    title="CPU Usage by Partition",
                    color="job_count",
                    labels={
                        "total_cpus": "Total CPUs Allocated",
                        "partition": "Partition",
                        "job_count": "Number of Jobs",
                    },
                    color_continuous_scale=px.colors.sequential.Viridis,
                )
                st.plotly_chart(fig, use_container_width=True)
            else:
                st.info(
                    "No resource utilization data available for the selected filters"
                )

            # Job duration distribution
            st.header("Job Duration Analysis")

            duration_query = f"""
            SELECT
                job_id,
                partition,
                (end_time - start_time) / 60 as duration_minutes
            FROM slurm_data.jobs
            WHERE
                submit_time BETWEEN {start_timestamp} AND {end_timestamp}
                AND end_time > 0
                AND start_time > 0
                {f"AND partition IN ({', '.join(['?' for _ in selected_partitions])})" if selected_partitions else ""}
            """

            duration_df = conn.execute(
                duration_query, selected_partitions if selected_partitions else []
            ).df()

            if not duration_df.empty:
                # Histogram of job durations
                fig = px.histogram(
                    duration_df,
                    x="duration_minutes",
                    color="partition",
                    nbins=50,
                    title="Job Duration Distribution (minutes)",
                    labels={
                        "duration_minutes": "Duration (minutes)",
                        "count": "Number of Jobs",
                    },
                    opacity=0.7,
                )
                st.plotly_chart(fig, use_container_width=True)
            else:
                st.info("No job duration data available for the selected filters")

            # Raw data section (expandable)
            with st.expander("View Raw Data"):
                st.subheader("Nodes Data")
                nodes_raw_query = "SELECT * FROM slurm_data.nodes LIMIT 100"
                nodes_raw_df = conn.execute(nodes_raw_query).df()
                st.dataframe(nodes_raw_df)

                st.subheader("Jobs Data")
                jobs_raw_query = f"""
                SELECT * FROM slurm_data.jobs
                WHERE submit_time BETWEEN {start_timestamp} AND {end_timestamp}
                {f"AND partition IN ({', '.join(['?' for _ in selected_partitions])})" if selected_partitions else ""}
                LIMIT 100
                """
                jobs_raw_df = conn.execute(
                    jobs_raw_query, selected_partitions if selected_partitions else []
                ).df()
                st.dataframe(jobs_raw_df)
    else:
        st.warning(
            "No job data available in the database. Please run the SLURM data pipeline first."
        )

except Exception as e:
    st.error(f"Error accessing database: {str(e)}")
    st.info(
        "Please run the SLURM data pipeline first to collect data from your SLURM cluster."
    )

# Footer
st.markdown("---")
st.markdown(
    "SLURM Monitoring Dashboard | Alfred Wegener Institute for Polar and Marine Research"
)
