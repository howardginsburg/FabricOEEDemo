import logging

import fabric.functions as fn

udf = fn.UserDataFunctions()


def _validate_target(line_id: str, target_oee: float, set_by: str) -> tuple[str, float, str]:
    line = (line_id or "").strip()
    setter = (set_by or "").strip() or "report"

    if not line:
        raise fn.UserThrownError("Select a production line before setting the OEE target.")

    try:
        target = float(target_oee)
    except (TypeError, ValueError) as exc:
        raise fn.UserThrownError("Target OEE must be a number between 0 and 1.") from exc

    if target < 0.0 or target > 1.0:
        raise fn.UserThrownError("Target OEE must be a fraction between 0 and 1, for example 0.75.")

    return line, target, setter


@udf.connection(argName="sqlDB", alias="OeeGovernance")
@udf.function()
def set_oee_target(sqlDB: fn.FabricSqlConnection, lineId: str, targetOee: float, setBy: str = "report") -> str:
    line, target, setter = _validate_target(lineId, targetOee, setBy)

    merge_sql = """
MERGE dbo.OeeTarget WITH (HOLDLOCK) AS target
USING (SELECT ? AS line_id, ? AS target_oee, ? AS set_by) AS source
ON target.line_id = source.line_id
WHEN MATCHED THEN
    UPDATE SET
        target_oee = source.target_oee,
        effective_date = CAST(SYSUTCDATETIME() AS DATE),
        set_by = source.set_by,
        updated_at = SYSUTCDATETIME()
WHEN NOT MATCHED THEN
    INSERT (line_id, target_oee, effective_date, set_by, updated_at)
    VALUES (source.line_id, source.target_oee, CAST(SYSUTCDATETIME() AS DATE), source.set_by, SYSUTCDATETIME());
"""

    connection = None
    cursor = None
    try:
        connection = sqlDB.connect()
        cursor = connection.cursor()
        cursor.execute(merge_sql, line, target, setter)
        connection.commit()
    except fn.UserThrownError:
        raise
    except Exception as exc:
        logging.exception("Failed to set OEE target for %s", line)
        raise fn.UserThrownError(
            "Could not save the OEE target. Confirm the OeeGovernance SQL connection "
            "alias and dbo.OeeTarget table are available, then try again."
        ) from exc
    finally:
        if cursor is not None:
            cursor.close()
        if connection is not None:
            connection.close()

    return f"Target OEE for {line} set to {target:.1%}."
