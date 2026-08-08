const wanted = [
    "name",
    "progress",
    "eta",
    "total_size",
    "downloaded",
    "amount_left",
    "dlspeed",
    "num_seeds",
    "num_leechs",
    "status",
    "ratio"
];

const allColumns = [
    "priority",
    "state_icon",
    "name",
    "size",
    "total_size",
    "progress",
    "status",
    "num_seeds",
    "num_leechs",
    "dlspeed",
    "upspeed",
    "downloaded",
    "uploaded",
    "amount_left",
    "eta",
    "ratio",
    "popularity",
    "category",
    "tags",
    "added_on",
    "completion_on",
    "creation_date",
    "tracker",
    "save_path",
    "download_limit",
    "upload_limit",
    "downloaded_session",
    "uploaded_session",
    "time_active",
    "seeding_time",
    "seen_complete",
    "last_activity",
    "availability",
    "last_seen_complete"
];

allColumns.forEach(column => {
    localStorage.setItem(
        `column_${column}_visible_torrentsTableDiv`,
        wanted.includes(column) ? "1" : "0"
    );
});

localStorage.setItem(
    "columns_order_torrentsTableDiv",
    wanted.join(",")
);

location.reload();
