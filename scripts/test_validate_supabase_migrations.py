import unittest

from scripts.validate_supabase_migrations import validate_sql


class MigrationGovernanceTests(unittest.TestCase):
    def test_internal_table_requires_explicit_revoke(self):
        sql = """
        create table public.internal_events (id bigint primary key);
        revoke all on table public.internal_events
        from public, anon, authenticated, service_role;
        """
        self.assertEqual([], validate_sql("supabase/migrations/20990101_internal.sql", sql))

    def test_table_without_access_declaration_fails(self):
        sql = "create table public.exposed_by_accident (id bigint primary key);"
        errors = validate_sql("supabase/migrations/20990101_bad.sql", sql)
        self.assertTrue(any("without an explicit GRANT or REVOKE" in e for e in errors))

    def test_client_table_requires_rls(self):
        sql = """
        create table public.client_rows (id bigint primary key);
        grant select on table public.client_rows to authenticated;
        """
        errors = validate_sql("supabase/migrations/20990101_bad_rls.sql", sql)
        self.assertTrue(any("without enabling Row Level Security" in e for e in errors))

    def test_client_table_with_rls_passes(self):
        sql = """
        create table public.client_rows (id bigint primary key);
        alter table public.client_rows enable row level security;
        grant select on table public.client_rows to authenticated;
        """
        self.assertEqual([], validate_sql("supabase/migrations/20990101_good_rls.sql", sql))

    def test_function_requires_explicit_execute_policy(self):
        sql = """
        create or replace function public.server_rpc()
        returns void language sql as $$ select null; $$;
        """
        errors = validate_sql("supabase/migrations/20990101_bad_rpc.sql", sql)
        self.assertTrue(any("without an explicit GRANT EXECUTE or REVOKE" in e for e in errors))

    def test_service_role_rpc_passes(self):
        sql = """
        create or replace function public.server_rpc()
        returns void language sql security definer as $$ select null; $$;
        revoke all on function public.server_rpc() from public, anon, authenticated;
        grant execute on function public.server_rpc() to service_role;
        """
        self.assertEqual([], validate_sql("supabase/migrations/20990101_good_rpc.sql", sql))

    def test_historical_recovery_marker_is_allowlisted(self):
        sql = """
        -- nds-migration-governance: restored-applied-migration
        create or replace function public.legacy_rpc()
        returns void language sql as $$ select null; $$;
        """
        path = (
            "supabase/migrations/"
            "20260903083200_harden_stripe_subscription_license_sync.sql"
        )
        self.assertEqual([], validate_sql(path, sql))

    def test_recovery_marker_cannot_bypass_future_migrations(self):
        sql = """
        -- nds-migration-governance: restored-applied-migration
        create table public.future_table (id bigint primary key);
        """
        errors = validate_sql("supabase/migrations/20990101_future.sql", sql)
        self.assertTrue(any("reserved for explicitly allowlisted" in e for e in errors))


if __name__ == "__main__":
    unittest.main()
