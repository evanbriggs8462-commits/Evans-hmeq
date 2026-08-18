// Read-only metadata export for Tabular Editor 2.
// The PowerShell wrapper sets TE2_OUTPUT_DIR and allowlists this script.

var outputDirectory = System.Environment.GetEnvironmentVariable("TE2_OUTPUT_DIR");
if (string.IsNullOrWhiteSpace(outputDirectory))
{
    throw new System.Exception("TE2_OUTPUT_DIR was not supplied by the wrapper.");
}

System.IO.Directory.CreateDirectory(outputDirectory);
var utf8WithBom = new System.Text.UTF8Encoding(true);

System.Func<object, string> Csv = value =>
{
    var text = value == null ? "" : value.ToString();
    return "\"" + text.Replace("\"", "\"\"") + "\"";
};

System.Func<object, string> ExpressionOf = value =>
{
    if (value == null)
    {
        return "";
    }

    var property = value.GetType().GetProperty("Expression");
    if (property == null)
    {
        return "";
    }

    var expression = property.GetValue(value, null);
    return expression == null ? "" : expression.ToString();
};

System.Action<string, System.Collections.Generic.List<string>> WriteCsv = (name, lines) =>
{
    var path = System.IO.Path.Combine(outputDirectory, name);
    System.IO.File.WriteAllLines(path, lines, utf8WithBom);
};

var tables = new System.Collections.Generic.List<string>();
tables.Add(string.Join(",", new[]
{
    Csv("Table"),
    Csv("ObjectType"),
    Csv("IsHidden"),
    Csv("Description")
}));
foreach (var table in Model.Tables)
{
    tables.Add(string.Join(",", new[]
    {
        Csv(table.Name),
        Csv(table.ObjectTypeName),
        Csv(table.IsHidden),
        Csv(table.Description)
    }));
}
WriteCsv("tables.csv", tables);

var measures = new System.Collections.Generic.List<string>();
measures.Add(string.Join(",", new[]
{
    Csv("Table"),
    Csv("Measure"),
    Csv("DisplayFolder"),
    Csv("FormatString"),
    Csv("IsHidden"),
    Csv("Description"),
    Csv("Expression")
}));
foreach (var table in Model.Tables)
{
    foreach (var measure in table.Measures)
    {
        measures.Add(string.Join(",", new[]
        {
            Csv(table.Name),
            Csv(measure.Name),
            Csv(measure.DisplayFolder),
            Csv(measure.FormatString),
            Csv(measure.IsHidden),
            Csv(measure.Description),
            Csv(measure.Expression)
        }));
    }
}
WriteCsv("measures.csv", measures);

var columns = new System.Collections.Generic.List<string>();
columns.Add(string.Join(",", new[]
{
    Csv("Table"),
    Csv("Column"),
    Csv("ColumnType"),
    Csv("DataType"),
    Csv("IsHidden"),
    Csv("DisplayFolder"),
    Csv("SortByColumn"),
    Csv("Description"),
    Csv("Expression")
}));
foreach (var table in Model.Tables)
{
    foreach (var column in table.Columns)
    {
        columns.Add(string.Join(",", new[]
        {
            Csv(table.Name),
            Csv(column.Name),
            Csv(column.Type),
            Csv(column.DataType),
            Csv(column.IsHidden),
            Csv(column.DisplayFolder),
            Csv(column.SortByColumn == null ? "" : column.SortByColumn.Name),
            Csv(column.Description),
            Csv(ExpressionOf(column))
        }));
    }
}
WriteCsv("columns.csv", columns);

var relationships = new System.Collections.Generic.List<string>();
relationships.Add(string.Join(",", new[]
{
    Csv("FromTable"),
    Csv("FromColumn"),
    Csv("ToTable"),
    Csv("ToColumn"),
    Csv("IsActive"),
    Csv("CrossFilteringBehavior")
}));
foreach (var relationship in Model.Relationships)
{
    relationships.Add(string.Join(",", new[]
    {
        Csv(relationship.FromTable.Name),
        Csv(relationship.FromColumn.Name),
        Csv(relationship.ToTable.Name),
        Csv(relationship.ToColumn.Name),
        Csv(relationship.IsActive),
        Csv(relationship.CrossFilteringBehavior)
    }));
}
WriteCsv("relationships.csv", relationships);

var partitions = new System.Collections.Generic.List<string>();
partitions.Add(string.Join(",", new[]
{
    Csv("Table"),
    Csv("Partition"),
    Csv("Mode"),
    Csv("SourceType"),
    Csv("Expression")
}));
foreach (var table in Model.Tables)
{
    foreach (var partition in table.Partitions)
    {
        partitions.Add(string.Join(",", new[]
        {
            Csv(table.Name),
            Csv(partition.Name),
            Csv(partition.Mode),
            Csv(partition.SourceType),
            Csv(partition.Expression)
        }));
    }
}
WriteCsv("partitions.csv", partitions);

var expressions = new System.Collections.Generic.List<string>();
expressions.Add(string.Join(",", new[]
{
    Csv("Expression"),
    Csv("Kind"),
    Csv("Description"),
    Csv("Definition")
}));
foreach (var expression in Model.Expressions)
{
    expressions.Add(string.Join(",", new[]
    {
        Csv(expression.Name),
        Csv(expression.Kind),
        Csv(expression.Description),
        Csv(expression.Expression)
    }));
}
WriteCsv("expressions.csv", expressions);
