revoke update, delete, truncate on table public.wallet_ledger from service_role;
revoke update, delete, truncate on table public.transactions from service_role;

grant select, insert on table public.wallet_ledger to service_role;
grant select, insert on table public.transactions to service_role;

