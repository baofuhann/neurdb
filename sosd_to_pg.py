#!/usr/bin/env python3
"""
SOSD to PostgreSQL Data Converter

Usage:
    python sosd_to_pg.py <sosd_file> [options]

Examples:
    # Generate CSV file
    python sosd_to_pg.py books_200M_uint32 --output books.csv --limit 100000

    # Generate SQL INSERT statements
    python sosd_to_pg.py books_200M_uint32 --output books.sql --format sql --limit 100000

    # Directly insert into PostgreSQL
    python sosd_to_pg.py books_200M_uint32 --direct --limit 100000
"""

import struct
import argparse
import sys
import os

def read_sosd_file(filepath, data_type='uint32', limit=None):
    """
    Read SOSD binary file and yield (id, value) tuples.

    Args:
        filepath: Path to SOSD binary file
        data_type: 'uint32' or 'uint64'
        limit: Maximum number of records to read (None for all)

    Yields:
        (id, value) tuples
    """
    type_size = 4 if data_type == 'uint32' else 8
    type_fmt = '<I' if data_type == 'uint32' else '<Q'

    with open(filepath, 'rb') as f:
        # Read record count (first 8 bytes)
        count_data = f.read(8)
        if len(count_data) < 8:
            raise ValueError("Invalid SOSD file: cannot read count")

        total_count = struct.unpack('<Q', count_data)[0]
        print(f"Total records in file: {total_count:,}")

        # Determine how many records to read
        read_count = total_count if limit is None else min(total_count, limit)
        print(f"Reading {read_count:,} records...")

        for i in range(read_count):
            data = f.read(type_size)
            if len(data) < type_size:
                print(f"Warning: Unexpected end of file at record {i}")
                break

            value = struct.unpack(type_fmt, data)[0]

            # For uint32, value fits in INT; for uint64, may need BIGINT
            # Convert to signed int32 range if needed for PostgreSQL INT type
            if data_type == 'uint32':
                # Keep as unsigned for now, PostgreSQL INT can handle 0 to 2^31-1
                # Values > 2^31-1 will need BIGINT
                if value > 2147483647:
                    value = value - 4294967296  # Convert to signed

            yield (i + 1, value)

            # Progress indicator
            if (i + 1) % 100000 == 0:
                print(f"  Processed {i + 1:,} records...")


def generate_csv(sosd_file, output_file, data_type='uint32', limit=None):
    """Generate CSV file from SOSD data, sorted by val."""
    # 先读取所有数据
    print("Reading all data...")
    data = list(read_sosd_file(sosd_file, data_type, limit))

    # 按 val 排序
    print(f"Sorting {len(data):,} records by val...")
    data.sort(key=lambda x: x[1])

    # 重新分配 id（排序后按顺序编号）
    print("Writing sorted data to CSV...")
    with open(output_file, 'w') as f:
        f.write("id,val\n")
        for new_id, (_, val) in enumerate(data, start=1):
            f.write(f"{new_id},{val}\n")
    print(f"CSV saved to: {output_file}")


def generate_sql(sosd_file, output_file, table_name='sosd_data', data_type='uint32', limit=None, batch_size=1000):
    """Generate SQL INSERT statements from SOSD data."""
    with open(output_file, 'w') as f:
        # Write CREATE TABLE statement
        f.write(f"-- SOSD Data Import Script\n")
        f.write(f"-- Source: {sosd_file}\n\n")
        f.write(f"DROP TABLE IF EXISTS {table_name};\n")
        f.write(f"CREATE TABLE {table_name} (\n")
        f.write(f"    id INT PRIMARY KEY,\n")
        f.write(f"    val INT\n")
        f.write(f");\n\n")

        # Write INSERT statements in batches
        batch = []
        for id, val in read_sosd_file(sosd_file, data_type, limit):
            batch.append(f"({id}, {val})")

            if len(batch) >= batch_size:
                f.write(f"INSERT INTO {table_name} (id, val) VALUES\n")
                f.write(",\n".join(batch))
                f.write(";\n\n")
                batch = []

        # Write remaining records
        if batch:
            f.write(f"INSERT INTO {table_name} (id, val) VALUES\n")
            f.write(",\n".join(batch))
            f.write(";\n")

    print(f"SQL saved to: {output_file}")


def generate_copy_format(sosd_file, output_file, data_type='uint32', limit=None):
    """Generate PostgreSQL COPY format (tab-separated, no header)."""
    with open(output_file, 'w') as f:
        for id, val in read_sosd_file(sosd_file, data_type, limit):
            f.write(f"{id}\t{val}\n")
    print(f"COPY format saved to: {output_file}")


def direct_insert(sosd_file, data_type='uint32', limit=None,
                  host='localhost', port=5432, user='neurdb', dbname='neurdb',
                  table_name='sosd_data', batch_size=10000):
    """Directly insert data into PostgreSQL."""
    try:
        import psycopg2
    except ImportError:
        print("Error: psycopg2 not installed. Install with: pip install psycopg2-binary")
        sys.exit(1)

    conn = psycopg2.connect(host=host, port=port, user=user, dbname=dbname)
    cur = conn.cursor()

    # Create table
    cur.execute(f"DROP TABLE IF EXISTS {table_name}")
    cur.execute(f"""
        CREATE TABLE {table_name} (
            id INT PRIMARY KEY,
            val INT
        )
    """)
    conn.commit()
    print(f"Created table: {table_name}")

    # Insert data in batches
    batch = []
    inserted = 0

    for id, val in read_sosd_file(sosd_file, data_type, limit):
        batch.append((id, val))

        if len(batch) >= batch_size:
            cur.executemany(f"INSERT INTO {table_name} (id, val) VALUES (%s, %s)", batch)
            conn.commit()
            inserted += len(batch)
            print(f"  Inserted {inserted:,} records...")
            batch = []

    # Insert remaining
    if batch:
        cur.executemany(f"INSERT INTO {table_name} (id, val) VALUES (%s, %s)", batch)
        conn.commit()
        inserted += len(batch)

    print(f"Total inserted: {inserted:,} records")

    cur.close()
    conn.close()


def main():
    parser = argparse.ArgumentParser(
        description='Convert SOSD benchmark data to PostgreSQL format',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Generate CSV (100K records)
  python sosd_to_pg.py books_200M_uint32 -o books.csv -l 100000

  # Generate SQL file
  python sosd_to_pg.py books_200M_uint32 -o books.sql -f sql -l 100000

  # Generate COPY format (fastest for large imports)
  python sosd_to_pg.py books_200M_uint32 -o books.dat -f copy -l 100000

  # Direct insert to PostgreSQL
  python sosd_to_pg.py books_200M_uint32 --direct -l 100000

SOSD datasets can be downloaded from:
  https://github.com/learnedsystems/SOSD
        """
    )

    parser.add_argument('sosd_file', help='Path to SOSD binary file')
    parser.add_argument('-o', '--output', help='Output file path')
    parser.add_argument('-f', '--format', choices=['csv', 'sql', 'copy'], default='csv',
                        help='Output format (default: csv)')
    parser.add_argument('-t', '--type', choices=['uint32', 'uint64'], default='uint32',
                        help='Data type in SOSD file (default: uint32)')
    parser.add_argument('-l', '--limit', type=int, default=100000,
                        help='Maximum records to read (default: 100000)')
    parser.add_argument('--table', default='sosd_data',
                        help='Table name (default: sosd_data)')
    parser.add_argument('--direct', action='store_true',
                        help='Directly insert into PostgreSQL')
    parser.add_argument('--host', default='localhost', help='PostgreSQL host')
    parser.add_argument('--port', type=int, default=5432, help='PostgreSQL port')
    parser.add_argument('--user', default='neurdb', help='PostgreSQL user')
    parser.add_argument('--dbname', default='neurdb', help='PostgreSQL database')

    args = parser.parse_args()

    # Check if SOSD file exists
    if not os.path.exists(args.sosd_file):
        print(f"Error: SOSD file not found: {args.sosd_file}")
        print("\nTo download SOSD datasets:")
        print("  git clone https://github.com/learnedsystems/SOSD")
        print("  cd SOSD && ./scripts/download.sh")
        sys.exit(1)

    if args.direct:
        direct_insert(
            args.sosd_file,
            data_type=args.type,
            limit=args.limit,
            host=args.host,
            port=args.port,
            user=args.user,
            dbname=args.dbname,
            table_name=args.table
        )
    else:
        if not args.output:
            # Default output filename
            base = os.path.basename(args.sosd_file)
            args.output = f"{base}.{args.format}"

        if args.format == 'csv':
            generate_csv(args.sosd_file, args.output, args.type, args.limit)
        elif args.format == 'sql':
            generate_sql(args.sosd_file, args.output, args.table, args.type, args.limit)
        elif args.format == 'copy':
            generate_copy_format(args.sosd_file, args.output, args.type, args.limit)

        # Print import instructions
        print("\n" + "="*60)
        print("To import into PostgreSQL:")
        print("="*60)

        if args.format == 'csv':
            print(f"""
/code/neurdb-dev/psql/bin/psql -h localhost -U neurdb << 'EOF'
DROP TABLE IF EXISTS {args.table};
CREATE TABLE {args.table} (id INT PRIMARY KEY, val INT);
\\copy {args.table} FROM '{os.path.abspath(args.output)}' CSV HEADER;
SELECT COUNT(*) FROM {args.table};

-- Create LIPP index
CREATE INDEX idx_{args.table}_val ON {args.table} USING nrindex(val);
EOF
""")
        elif args.format == 'sql':
            print(f"""
/code/neurdb-dev/psql/bin/psql -h localhost -U neurdb -f {os.path.abspath(args.output)}

-- Then create index:
/code/neurdb-dev/psql/bin/psql -h localhost -U neurdb -c "CREATE INDEX idx_{args.table}_val ON {args.table} USING nrindex(val);"
""")
        elif args.format == 'copy':
            print(f"""
/code/neurdb-dev/psql/bin/psql -h localhost -U neurdb << 'EOF'
DROP TABLE IF EXISTS {args.table};
CREATE TABLE {args.table} (id INT, val INT);
\\copy {args.table} FROM '{os.path.abspath(args.output)}';
SELECT COUNT(*) FROM {args.table};

-- Create LIPP index
CREATE INDEX idx_{args.table}_val ON {args.table} USING nrindex(val);
EOF
""")


if __name__ == '__main__':
    main()
