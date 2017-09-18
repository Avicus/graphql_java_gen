package com.shopify.graphql.support;

/**
 * Created by eapache on 2015-11-17.
 */
public abstract class Query<T extends Query> {
    public static final String ALIAS_SUFFIX_SEPARATOR = "__";
    private static final String ALIAS_DELIMITER = ":";
    protected final StringBuilder _queryBuilder;
    private boolean firstSelection = true;
    private String aliasSuffix = null;

    protected Query(StringBuilder queryBuilder) {
        this._queryBuilder = queryBuilder;
    }

    public static void appendQuotedString(StringBuilder query, String string) {
        query.append('"');
        for (char c : string.toCharArray()) {
            switch (c) {
                case '"':
                case '\\':
                    query.append('\\');
                    query.append(c);
                    break;
                case '\r':
                    query.append("\\r");
                    break;
                case '\n':
                    query.append("\\n");
                    break;
                default:
                    if (c < 0x20) {
                        query.append(String.format("\\u%04x", (int) c));
                    } else {
                        query.append(c);
                    }
                    break;
            }
        }
        query.append('"');
    }

    private void startSelection() {
        if (firstSelection) {
            firstSelection = false;
        } else {
            builder().append(',');
        }
    }

    protected void startInlineFragment(String typeName) {
        if (aliasSuffix != null) {
            throw new IllegalStateException("An alias cannot be specified on inline fragments");
        }

        startSelection();
        builder().append("... on ");
        builder().append(typeName);
        builder().append('{');
    }

    protected void startField(String fieldName) {
        startSelection();
        builder().append(fieldName);
        if (aliasSuffix != null) {
            builder().append(ALIAS_SUFFIX_SEPARATOR);
            builder().append(aliasSuffix);
            builder().append(ALIAS_DELIMITER);
            builder().append(fieldName);
            aliasSuffix = null;
        }
    }

    public T withAlias(String aliasSuffix) {
        if (this.aliasSuffix != null) {
            throw new IllegalStateException("Can only define a single alias for a field");
        }
        if (aliasSuffix == null || aliasSuffix.isEmpty()) {
            throw new IllegalArgumentException("Can't specify an empty alias");
        }
        if (aliasSuffix.contains(Query.ALIAS_SUFFIX_SEPARATOR)) {
            throw new IllegalArgumentException("Alias must not contain __");
        }
        this.aliasSuffix = aliasSuffix;
        // noinspection unchecked
        return (T) this;
    }
}
