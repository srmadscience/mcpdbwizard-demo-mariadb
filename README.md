# mcpdbwizard-demo-mariadb

A demo MariaDB schema for [MCPDBWizard for MariaDB](https://mcpdbwizard.com/docs/mariadb/): a small
hotel booking database with enough tables, views, constraints and routines to show a generator that
turns a schema into an MCP server.

You point MCPDBWizard at a database and select the objects you are willing to expose, and it
generates an MCP server that has tools for those objects and nothing else. Objects you did not
select are absent from the generated server rather than blocked at request time:
[the config is the security model](https://mcpdbwizard.com/docs/configs/). This repository is the
other half of that exercise: the schema to point it at, plus two saved configs that already make the
interesting choices.

It is the MariaDB port of the Oracle demo in
[mcpdbwizard-demo](https://github.com/srmadscience/mcpdbwizard-demo): the same hotels, rooms,
customers and bookings, and the same two configs.

## Contents

| File | Purpose |
| --- | --- |
| `db/mcp_db_demo_user.sql` | Creates the `mcpdemo` database and login. Run once, as root |
| `db/mcp_db_demo_ddl.sql` | Tables, indexes, views, sequences, `upsert_customer`, `hotel_occupancy`, and the `room_manager_*` and `customer_portal_*` routines |
| `db/mcp_db_demo_dml.sql` | Sample data: 10 hotels, 21 amenities, 52 rooms, 43 customers, 92 bookings, 7 complaints |
| `db/mcp_db_demo_drop.sql` | Drops everything the DDL creates |
| `sql/*.sql` | The hand-written queries exposed as tools, one file per tool, for reading. The config carries its own copy of every statement |
| `config/mcpdemo_customer.json` | A config for a **customer-facing** agent: [Context Pinning](https://mcpdbwizard.com/docs/context-pinning/), one customer per connection, chosen by the URL |
| `config/mcpdemo.json` | A config for a **staff** agent, which sees every customer |

**Use MariaDB 12.3 or later.** The routines that return a cursor (`customer_portal_my_bookings`,
`customer_portal_my_complaints`, `room_manager_getroomlist`, `room_manager_bookroom`,
`hotel_occupancy`) need 12.3's `SYS_REFCURSOR`. The DDL loads on 11.4 and 11.8 too, but there those
five return a placeholder string instead of rows.

## Installing

```sh
mariadb -h <host> -u root -p < db/mcp_db_demo_user.sql                # once, as root
mariadb -h <host> -u mcpdemo -pmcpdemo mcpdemo < db/mcp_db_demo_ddl.sql
mariadb -h <host> -u mcpdemo -pmcpdemo mcpdemo < db/mcp_db_demo_dml.sql
```

The user script creates the database `mcpdemo` and a login `mcpdemo` with the password `mcpdemo`,
which owns it. Change the password for anything but a demo on your own machine. If the server has
binary logging on, creating the demo's function as `mcpdemo` also needs
`SET GLOBAL log_bin_trust_function_creators = 1`, or run the DDL as root.

Oracle's packages become routines named `<package>_<member>`:

| Routines | For | Oracle equivalent |
| --- | --- | --- |
| `upsert_customer`, `hotel_occupancy` | Staff | Standalone procedures in `MCPDEMO` |
| `room_manager_getroomlist`, `room_manager_bookroom` | Staff | The `ROOM_MANAGER` package |
| `customer_portal_my_details`, `_my_bookings`, `_book_rooms`, `_cancel_booking`, `_my_complaints`, `_add_complaint` | One customer | The `CUSTOMER_PORTAL` package |

There are no migrations. This is demo data, so to start again, drop it and build it again:

```sh
mariadb -h <host> -u mcpdemo -pmcpdemo mcpdemo < db/mcp_db_demo_drop.sql
mariadb -h <host> -u mcpdemo -pmcpdemo mcpdemo < db/mcp_db_demo_ddl.sql
mariadb -h <host> -u mcpdemo -pmcpdemo mcpdemo < db/mcp_db_demo_dml.sql
```

## Running MCPDBWizard against it

[Quickstart: MariaDB](https://mcpdbwizard.com/docs/quickstart-mariadb/) has the full version.
Pointed at this database, the container looks like this:

```sh
docker run -d --name mcpdbwizard-mariadb \
  -p 8080:8080 \
  -v mcpdbwizard-data:/data \
  -e MCPDBWIZARD_DB_HOST=your.db.host \
  -e MCPDBWIZARD_DB_NAME=mcpdemo \
  -e MCPDBWIZARD_DB_USER=mcpdemo \
  -e DB_PASS=mcpdemo \
  ghcr.io/srmadscience/mcpdbwizard-mariadb:2.0.36
```

A database on the Docker host itself is `host.docker.internal`, not `localhost`.

Sign in at <http://localhost:8080> as `admin`; the first password is in
`/data/initial-admin-password` (`docker exec mcpdbwizard-mariadb cat /data/initial-admin-password`).

### One customer per connection

Upload `config/mcpdemo_customer.json` on the Configs tab. Uploading saves it, with the connection
filled in from the container's settings, and the config carries the text of its SQL statements, so
there is nothing else to copy. Press **Generate & run** on the Runtime page, issue a token on the
Users page, and connect through the proxy on 8080, naming the customer in the URL:

```sh
claude mcp add hotel-suzy --transport http \
  "http://localhost:8080/mcp/admin/mcpdemo_customer?CUSTOMER_NAME=SUZY%20BISHOP" \
  --header "Authorization: Bearer <id>.<secret>"
```

None of the routines takes a customer name. They read the customer from the connection URL instead,
where the model cannot see or change it: MCPDBWizard sets it as the user variable
`@mcp_customer_name` at the start of each tool call, and `customer_portal_current_customer` reads it.
So `customer_portal_my_details` answers for Suzy Bishop and nobody else, `customer_portal_my_bookings`
returns only her bookings, a connection without `CUSTOMER_NAME` is refused, and an unknown name is
refused by the database itself (`Customer ... is not known to this hotel chain`, error 20101). Nothing
needs installing in the database for this.

Then ask the agent what rooms are free at Asteroid City Inn next week, and to book one.

### The staff config

`config/mcpdemo.json` is the staff version: it sees every customer, can create or update one through
`upsert_customer`, books through `room_manager_bookroom`, and reports occupancy. The free tier runs
one server at a time, so stop `mcpdemo_customer` before you start `mcpdemo`.

Both configs have `mcpHttpToken`, `mcpHttps` and `mcpOAuth` set to `NO`, which is fine for a demo on
your own machine and not fine anywhere else. Every tool call commits, so bookings, complaints and
customers an agent creates stay in the database until you rebuild it.

## The schema

| Table | Holds |
| --- | --- |
| `hotels` | One row per hotel, with a region, a star rating and a customer rating |
| `hotel_amenities` | What each hotel offers, and whether it is chargeable |
| `hotel_rooms` | Room numbers, with optional notes on what makes a room unusual |
| `customers` | Customer name, phone number and email address |
| `room_bookings` | Who is in which room, between which dates |
| `complaints` | What a customer complained about, when, and whether it was resolved |

Every join is a real constraint. Deleting a hotel takes its rooms and amenities with it, and the rooms
take their bookings. Nothing cascades from `customers`, so a customer with a booking or a complaint on
file cannot be deleted until those go first.

Two views summarise the reference data: `hotel_regions` aggregates ratings by region, and
`hotel_amenities_summary` gives the percentage of hotels that charge for each amenity.

The sample bookings deliberately include hotels that are sold out for parts of the range, so occupancy
and availability have something to report other than "yes, there is a room".

## How it differs from the Oracle demo

- Oracle's packages are routines named `<package>_<member>`, so `ROOM_MANAGER.BOOKROOM` is
  `room_manager_bookroom`, and so is its tool.
- `DATE` columns are `datetime`, `NUMBER(p,s)` is `decimal(p,s)`, and PL/SQL's `NATURAL` is
  `int unsigned`.
- Context Pinning reads the user variable `@mcp_customer_name` where Oracle reads
  `SYS_CONTEXT('MCP', 'CUSTOMER_NAME')`, and needs no context installed.
- `room_manager_bookroom` starts its own transaction when the caller has none, so its `ROLLBACK`,
  when it cannot book every room asked for, undoes its own bookings as Oracle's does.

The header of `db/mcp_db_demo_ddl.sql` lists the rest.

## Licence

Apache License 2.0; see [LICENSE](LICENSE). MCPDBWizard itself is proprietary software from ATB
Consultancy Services Ltd: see <https://mcpdbwizard.com>.
