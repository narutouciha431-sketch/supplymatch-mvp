-- =====================================================================
-- SupplyMatch — база данных для Supabase
-- Как запустить: Supabase → SQL Editor → New query → вставить весь файл → Run.
-- Скрипт можно запускать повторно: он не удаляет данные, демо-данные
-- добавляются только в пустую базу.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- Таблицы ----------

-- Аккаунты: магазин или продавец. id = id пользователя в Supabase Auth
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  role       text not null check (role in ('shop','seller')),
  name       text not null check (char_length(name) between 2 and 60),
  phone      text not null unique check (phone ~ '^7[0-9]{10}$'),
  created_at timestamptz not null default now()
);

-- Продавцы. owner = null у демо-продавцов (у них нет живого аккаунта)
create table if not exists public.producers (
  id         text primary key default 'p' || substr(md5(random()::text), 1, 12),
  owner      uuid unique references public.profiles(id) on delete set null,
  name       text not null,
  type       text not null default 'home' check (type in ('farm','home','whole')),
  dist       text not null default 'taraz',
  cats       text[] not null default '{}',
  goods      text not null default '',
  descr      jsonb not null default '{"ru":"","kz":""}',
  deals      int  not null default 0,
  demo_phone text,
  created_at timestamptz not null default now()
);

-- Совместные закупки (партии)
create table if not exists public.pools (
  id         text primary key default 'g' || substr(md5(random()::text), 1, 12),
  producer   text not null references public.producers(id) on delete cascade,
  item       jsonb not null,                       -- {"ru":"Картофель","kz":"Картоп"}
  cat        text not null check (cat in ('veg','fruit','dairy','meat','grain','honey')),
  unit       text not null check (unit in ('кг','л')),
  target     int  not null check (target > 0),     -- объём партии
  got        int  not null default 0 check (got >= 0),
  extra      int  not null default 0,              -- демо-магазины, уже вошедшие в сбор
  members    int  not null default 0,              -- всего магазинов в сборе
  retail     int,                                   -- цена на рынке (может быть неизвестна)
  price      int  not null check (price > 0),       -- цена партии
  deadline   timestamptz not null,
  status     text not null default 'open' check (status in ('open','full','shipped','done','cancelled')),
  created_at timestamptz not null default now()
);

-- Заказы магазинов (один активный заказ магазина на одну закупку)
create table if not exists public.orders (
  id         uuid primary key default gen_random_uuid(),
  pool       text not null references public.pools(id) on delete cascade,
  shop       uuid not null references public.profiles(id) on delete cascade,
  qty        int  not null check (qty > 0),
  total      numeric not null default 0,
  saved      numeric,
  status     text not null default 'wait' check (status in ('wait','ready','shipped','done','cancelled')),
  rating     int check (rating between 1 and 5),
  created_at timestamptz not null default now()
);
create index if not exists orders_pool_idx on public.orders(pool);
create index if not exists orders_shop_idx on public.orders(shop);

-- Отзывы: только по полученному заказу, один на заказ
create table if not exists public.reviews (
  id         bigserial primary key,
  producer   text not null references public.producers(id) on delete cascade,
  author     text not null,
  body       text not null default '',
  stars      int  not null check (stars between 1 and 5),
  order_id   uuid unique references public.orders(id) on delete set null,
  created_at timestamptz not null default now()
);

-- ---------- Права доступа (RLS) ----------
-- Читать можно по правилам ниже. Писать напрямую в таблицы нельзя никому:
-- все изменения идут только через функции внизу, которые проверяют правила.

alter table public.profiles  enable row level security;
alter table public.producers enable row level security;
alter table public.pools     enable row level security;
alter table public.orders    enable row level security;
alter table public.reviews   enable row level security;

drop policy if exists "producers: читают все" on public.producers;
create policy "producers: читают все" on public.producers for select using (true);

drop policy if exists "pools: читают все" on public.pools;
create policy "pools: читают все" on public.pools for select using (true);

drop policy if exists "reviews: читают все" on public.reviews;
create policy "reviews: читают все" on public.reviews for select using (true);

-- Имена и телефоны видят только вошедшие пользователи
drop policy if exists "profiles: только вошедшие" on public.profiles;
create policy "profiles: только вошедшие" on public.profiles for select to authenticated using (true);

-- Заказ видят сам магазин и продавец этого товара
drop policy if exists "orders: магазин и продавец" on public.orders;
create policy "orders: магазин и продавец" on public.orders for select to authenticated using (
  shop = auth.uid()
  or exists (select 1 from public.pools pl join public.producers pr on pr.id = pl.producer
             where pl.id = orders.pool and pr.owner = auth.uid())
);

revoke insert, update, delete, truncate on all tables in schema public from anon, authenticated;
revoke usage on all sequences in schema public from anon, authenticated;
grant select on public.producers, public.pools, public.reviews to anon, authenticated;
grant select on public.profiles, public.orders to authenticated;

-- ---------- Вспомогательные функции ----------

-- Примерное расстояние района до Тараза, км (то же, что на сайте)
create or replace function public.sm_km(d text) returns int language sql immutable as $$
  select case d when 'sarykemer' then 15 when 'asa' then 25 when 'zhualy' then 90
                when 'karatau' then 110 when 'merke' then 150 when 'kulan' then 190
                when 'shu' then 270 else 0 end
$$;

-- Тариф (демо): 3 000 ₸ + 150 ₸/км, по Таразу 2 000 ₸
create or replace function public.sm_trip(km int) returns numeric language sql immutable as $$
  select (case when km = 0 then 2000 else 3000 + km * 150 end)::numeric
$$;

-- Ошибка с кодом, который сайт переводит в понятный текст
create or replace function public.sm_err(code text) returns void language plpgsql as $$
begin
  raise exception using message = 'SM:' || code;
end $$;

-- ---------- Действия ----------

-- Срок сбора вышел, а партия не собрана → сбор отменяется, деньги «возвращаются»
create or replace function public.expire_pools() returns void
language plpgsql security definer set search_path = public as $$
begin
  update orders o set status = 'cancelled'
    from pools p
   where o.pool = p.id and p.status = 'open' and p.deadline < now() and o.status = 'wait';
  update pools set status = 'cancelled' where status = 'open' and deadline < now();
end $$;

-- Профиль после регистрации. Телефон должен совпадать с логином аккаунта
create or replace function public.register_profile(p_role text, p_name text, p_phone text,
                                                   p_type text default null, p_dist text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then perform sm_err('auth'); end if;
  if p_role not in ('shop','seller') then perform sm_err('role'); end if;
  if char_length(trim(coalesce(p_name,''))) < 2 then perform sm_err('err_name'); end if;
  if coalesce(p_phone,'') !~ '^7[0-9]{10}$'
     or split_part(coalesce(auth.jwt() ->> 'email',''), '@', 1) <> p_phone then
    perform sm_err('err_phone');
  end if;
  if exists (select 1 from profiles where phone = p_phone and id <> v_uid) then perform sm_err('err_phone_used'); end if;

  insert into profiles(id, role, name, phone) values (v_uid, p_role, left(trim(p_name), 60), p_phone)
  on conflict (id) do nothing;

  if p_role = 'seller' and not exists (select 1 from producers where owner = v_uid) then
    insert into producers(owner, name, type, dist, descr)
    values (v_uid, left(trim(p_name), 60),
            case when p_type in ('farm','home','whole') then p_type else 'home' end,
            coalesce(p_dist, 'taraz'),
            '{"ru":"Новый продавец на платформе.","kz":"Платформадағы жаңа сатушы."}');
  end if;
end $$;

-- Магазин покупает в закупке. Повторная покупка добавляется к тому же заказу
create or replace function public.join_pool(p_pool text, p_qty int) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_pool pools; v_prod producers; v_ord orders;
  v_qty int; v_goods numeric; v_total numeric;
begin
  if v_uid is null then perform sm_err('auth'); end if;
  if not exists (select 1 from profiles where id = v_uid and role = 'shop') then perform sm_err('only_shops'); end if;

  select * into v_pool from pools where id = p_pool for update;   -- блокировка: никто не «перепрыгнет» объём
  if not found or v_pool.status <> 'open' or v_pool.deadline < now() then perform sm_err('closed'); end if;
  select * into v_prod from producers where id = v_pool.producer;
  if v_prod.owner = v_uid then perform sm_err('own'); end if;
  if p_qty is null or p_qty < 1 or p_qty > v_pool.target - v_pool.got then perform sm_err('err_kg'); end if;

  select * into v_ord from orders where pool = v_pool.id and shop = v_uid and status = 'wait' for update;
  v_qty   := coalesce(v_ord.qty, 0) + p_qty;
  v_goods := v_qty * v_pool.price;
  v_total := v_goods
           + sm_trip(sm_km(v_prod.dist)) * ceil(v_pool.target / 1500.0) * v_qty / v_pool.target
           + v_goods * 0.05;

  if v_ord.id is null then
    insert into orders(pool, shop, qty, total, saved)
    values (v_pool.id, v_uid, v_qty, round(v_total),
            case when v_pool.retail is null then null else round(v_qty * v_pool.retail - v_total) end);
    update pools set members = members + 1 where id = v_pool.id;
  else
    update orders set qty = v_qty, total = round(v_total),
           saved = case when v_pool.retail is null then null else round(v_qty * v_pool.retail - v_total) end
     where id = v_ord.id;
  end if;

  update pools set got = got + p_qty where id = v_pool.id returning * into v_pool;

  if v_pool.got >= v_pool.target then
    update pools  set status = 'full'  where id = v_pool.id;
    update orders set status = 'ready' where pool = v_pool.id and status = 'wait';
    if v_prod.owner is null then                     -- демо-продавец отправляет сразу
      update pools  set status = 'shipped' where id = v_pool.id;
      update orders set status = 'shipped' where pool = v_pool.id and status = 'ready';
      return 'shipped';
    end if;
    return 'full';
  end if;
  return 'open';
end $$;

-- Магазин отказывается, пока идёт сбор
create or replace function public.cancel_order(p_order uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_ord orders;
begin
  select * into v_ord from orders where id = p_order and shop = auth.uid() for update;
  if not found or v_ord.status <> 'wait' then perform sm_err('state'); end if;
  update orders set status = 'cancelled' where id = v_ord.id;
  update pools set got = greatest(0, got - v_ord.qty), members = greatest(0, members - 1)
   where id = v_ord.pool and status = 'open';
end $$;

-- Магазин подтверждает, что получил товар
create or replace function public.receive_order(p_order uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_ord orders;
begin
  select * into v_ord from orders where id = p_order and shop = auth.uid() for update;
  if not found or v_ord.status <> 'shipped' then perform sm_err('state'); end if;
  update orders set status = 'done' where id = v_ord.id;
  update producers set deals = deals + 1 where id = (select producer from pools where id = v_ord.pool);
  if not exists (select 1 from orders where pool = v_ord.pool and status not in ('done','cancelled')) then
    update pools set status = 'done' where id = v_ord.pool and status = 'shipped';
  end if;
end $$;

-- Оценка: только по полученному заказу и только один раз
create or replace function public.rate_order(p_order uuid, p_stars int, p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare v_ord orders;
begin
  select * into v_ord from orders where id = p_order and shop = auth.uid() for update;
  if not found or v_ord.status <> 'done' or v_ord.rating is not null then perform sm_err('state'); end if;
  if p_stars is null or p_stars not between 1 and 5 then perform sm_err('state'); end if;
  update orders set rating = p_stars where id = v_ord.id;
  insert into reviews(producer, author, body, stars, order_id)
  select pl.producer, (select name from profiles where id = auth.uid()), left(coalesce(p_body,''), 300), p_stars, v_ord.id
    from pools pl where pl.id = v_ord.pool;
end $$;

-- Продавец отправил собранную партию
create or replace function public.ship_pool(p_pool text) returns void
language plpgsql security definer set search_path = public as $$
declare v_pool pools;
begin
  select pl.* into v_pool from pools pl join producers pr on pr.id = pl.producer
   where pl.id = p_pool and pr.owner = auth.uid() for update of pl;
  if not found or v_pool.status <> 'full' then perform sm_err('state'); end if;
  update pools  set status = 'shipped' where id = v_pool.id;
  update orders set status = 'shipped' where pool = v_pool.id and status = 'ready';
  if not exists (select 1 from orders where pool = v_pool.id and status not in ('done','cancelled')) then
    update pools set status = 'done' where id = v_pool.id;
  end if;
end $$;

-- Продавец отменяет сбор, пока он открыт → всем магазинам деньги возвращаются
create or replace function public.cancel_pool(p_pool text) returns void
language plpgsql security definer set search_path = public as $$
declare v_pool pools;
begin
  select pl.* into v_pool from pools pl join producers pr on pr.id = pl.producer
   where pl.id = p_pool and pr.owner = auth.uid() for update of pl;
  if not found or v_pool.status <> 'open' then perform sm_err('state'); end if;
  update pools  set status = 'cancelled' where id = v_pool.id;
  update orders set status = 'cancelled' where pool = v_pool.id and status = 'wait';
end $$;

-- Продавец размещает объявление (новую закупку)
create or replace function public.add_pool(p_item text, p_cat text, p_unit text, p_target int,
                                           p_price int, p_retail int, p_days int) returns text
language plpgsql security definer set search_path = public as $$
declare v_prod producers; v_id text; v_item text := trim(coalesce(p_item,''));
begin
  select * into v_prod from producers where owner = auth.uid();
  if not found then perform sm_err('only_sellers'); end if;
  if char_length(v_item) not between 1 and 40
     or p_cat not in ('veg','fruit','dairy','meat','grain','honey')
     or p_unit not in ('кг','л')
     or coalesce(p_target,0) not between 1 and 1000000
     or coalesce(p_price,0) < 1 then
    perform sm_err('err_add');
  end if;
  if p_retail is not null and p_retail <= p_price then perform sm_err('err_retail'); end if;
  if coalesce(p_days,0) not in (3,5,7,10) then perform sm_err('err_add'); end if;

  insert into pools(producer, item, cat, unit, target, price, retail, deadline)
  values (v_prod.id, jsonb_build_object('ru', v_item, 'kz', v_item), p_cat, p_unit, p_target, p_price, p_retail,
          now() + make_interval(days => p_days))
  returning id into v_id;

  update producers
     set cats  = case when p_cat = any(cats) then cats else cats || p_cat end,
         goods = case when position(lower(v_item) in lower(goods)) > 0 then goods
                      else trim(goods || ' ' || lower(v_item)) end
   where id = v_prod.id;
  return v_id;
end $$;

revoke execute on all functions in schema public from public, anon;
grant execute on function public.expire_pools() to anon, authenticated;
grant execute on function public.register_profile(text,text,text,text,text),
                          public.join_pool(text,int), public.cancel_order(uuid),
                          public.receive_order(uuid), public.rate_order(uuid,int,text),
                          public.ship_pool(text), public.cancel_pool(text),
                          public.add_pool(text,text,text,int,int,int,int) to authenticated;

-- ---------- Обновления в реальном времени ----------
do $$
declare t text;
begin
  foreach t in array array['producers','pools','orders','reviews'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;

-- ---------- Демо-данные (только в пустую базу) ----------
do $$
begin
  if exists (select 1 from public.producers) then return; end if;

  insert into public.producers(id, name, type, dist, cats, goods, descr, deals, demo_phone) values
  ('p1','Ферма «Береке»','farm','sarykemer','{veg}','картофель лук морковь капуста','{"ru":"Семейная ферма, своё поле.","kz":"Отбасылық ферма, өз егістігі бар."}',64,'77000000002'),
  ('p2','Ата Серік','home','asa','{veg,honey}','помидоры огурцы зелень мёд','{"ru":"Свой огород и пасека. Заявки принимает внук по телефону.","kz":"Өз бақшасы мен омартасы бар. Өтінімді немересі телефонмен қабылдайды."}',12,'77000000003'),
  ('p3','Апа Гүлнар','home','zhualy','{dairy}','курт сметана масло творог','{"ru":"Домашняя молочка из своего хозяйства.","kz":"Өз шаруашылығынан үй сүт өнімдері."}',21,'77000000004'),
  ('p4','КХ «Мерке Бақ»','farm','merke','{fruit}','яблоки абрикосы арбуз дыня','{"ru":"Сады и бахча, сезонные фрукты.","kz":"Бау-бақша, маусымдық жемістер."}',38,'77000000005'),
  ('p5','ТОО «Жамбыл Ет»','whole','taraz','{meat}','говядина баранина фарш халяль','{"ru":"Оптовый поставщик мяса, халяль.","kz":"Еттің көтерме жеткізушісі, халал."}',140,'77000000006'),
  ('p6','КХ «Шу Дала»','farm','shu','{grain,veg}','мука рис гречка лук','{"ru":"Крупное хозяйство, крупы и лук.","kz":"Ірі шаруашылық, жарма мен пияз."}',52,'77000000007'),
  ('p7','Молочная ферма «Ақ Бұлақ»','farm','karatau','{dairy}','молоко айран кефир сметана','{"ru":"Своё стадо, ежедневная дойка.","kz":"Өз табыны, күнделікті сауын."}',88,'77000000008');

  insert into public.pools(id, producer, item, cat, unit, target, got, extra, members, retail, price, deadline) values
  ('g1','p1','{"ru":"Картофель","kz":"Картоп"}','veg','кг',2000,1360,5,5,190,140, now() + interval '2 days'),
  ('g2','p7','{"ru":"Молоко","kz":"Сүт"}','dairy','л',600,510,6,6,420,330, now() + interval '1 day'),
  ('g3','p4','{"ru":"Яблоки","kz":"Алма"}','fruit','кг',1000,420,3,3,450,350, now() + interval '4 days'),
  ('g4','p5','{"ru":"Говядина","kz":"Сиыр еті"}','meat','кг',300,90,2,2,3800,3300, now() + interval '5 days'),
  ('g5','p6','{"ru":"Лук","kz":"Пияз"}','veg','кг',1500,700,4,4,160,115, now() + interval '3 days'),
  ('g6','p3','{"ru":"Курт","kz":"Құрт"}','dairy','кг',50,18,3,3,6000,4800, now() + interval '6 days');

  insert into public.reviews(producer, author, body, stars, created_at) values
  ('p1','Магазин «Айгерим»','Картошка чистая, крупная.',5, now() - interval '3 days'),
  ('p1','Минимаркет «Достық»','Привезли вовремя.',5, now() - interval '5 days'),
  ('p2','Кафе «Арай»','Мёд настоящий, помидоры сладкие.',5, now() - interval '4 days'),
  ('p3','Магазин «Айгерим»','Курт расходится за день.',5, now() - interval '2 days'),
  ('p3','Минимаркет «Нұр»','Иногда мало объёма.',4, now() - interval '6 days'),
  ('p4','Минимаркет «Достық»','Яблоки отличные.',5, now() - interval '2 days'),
  ('p4','Магазин «Береке»','Арбузы привезли с опозданием.',4, now() - interval '7 days'),
  ('p5','Донерная «Тоқаш»','Стабильное качество.',5, now() - interval '1 day'),
  ('p5','Кафе «Арай»','Цена выше рынка, но надёжно.',4, now() - interval '8 days'),
  ('p6','Магазин «Береке»','Мука хорошая.',4, now() - interval '3 days'),
  ('p7','Минимаркет «Нұр»','Молоко свежее каждый день.',5, now() - interval '2 days'),
  ('p7','Магазин «Айгерим»','Айран вкусный.',5, now() - interval '4 days');
end $$;

-- Чтобы через месяц демо-закупки не истекли все разом, обновить сроки можно так:
-- update public.pools set deadline = now() + interval '5 days', status = 'open' where id like 'g_' and status = 'cancelled';
