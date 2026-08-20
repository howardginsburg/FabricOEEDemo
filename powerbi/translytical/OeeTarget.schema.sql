IF OBJECT_ID(N'dbo.OeeTarget', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.OeeTarget
    (
        line_id NVARCHAR(64) NOT NULL,
        target_oee FLOAT NOT NULL,
        effective_date DATE NOT NULL,
        set_by NVARCHAR(256) NOT NULL,
        updated_at DATETIME2(7) NOT NULL,
        CONSTRAINT PK_OeeTarget PRIMARY KEY CLUSTERED (line_id),
        CONSTRAINT CK_OeeTarget_TargetRange CHECK (target_oee >= 0.0 AND target_oee <= 1.0)
    );
END;
GO

MERGE dbo.OeeTarget WITH (HOLDLOCK) AS target
USING
(
    VALUES
        (N'Line-A', 0.75, CAST(SYSUTCDATETIME() AS DATE), N'seed'),
        (N'Line-B', 0.75, CAST(SYSUTCDATETIME() AS DATE), N'seed'),
        (N'Line-C', 0.75, CAST(SYSUTCDATETIME() AS DATE), N'seed'),
        (N'Line-D', 0.75, CAST(SYSUTCDATETIME() AS DATE), N'seed'),
        (N'Line-E', 0.75, CAST(SYSUTCDATETIME() AS DATE), N'seed')
) AS source(line_id, target_oee, effective_date, set_by)
ON target.line_id = source.line_id
WHEN NOT MATCHED THEN
    INSERT (line_id, target_oee, effective_date, set_by, updated_at)
    VALUES (source.line_id, source.target_oee, source.effective_date, source.set_by, SYSUTCDATETIME());
GO
