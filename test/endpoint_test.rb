# frozen_string_literal: true

require "test_helper"

class EndpointTest < Minitest::Test
  TOKEN = "t" * 40

  def test_404_when_token_unset
    with_env("UPSTATE_HEALTH_TOKEN" => nil) do
      assert_equal 404, get_health(token: TOKEN).status
    end
  end

  def test_404_when_token_empty
    with_env("UPSTATE_HEALTH_TOKEN" => "") do
      assert_equal 404, get_health.status
    end
  end

  def test_401_without_or_with_bad_bearer
    with_env("UPSTATE_HEALTH_TOKEN" => TOKEN) do
      assert_equal 401, get_health.status
      assert_equal 401, get_health(token: "nope").status
      assert_equal 401, get_health(token: "x" * 300).status
      res = Rack::MockRequest.new(Upstate::Rails::Endpoint.new).get("/", "HTTP_AUTHORIZATION" => "Basic #{TOKEN}")
      assert_equal 401, res.status
    end
  end

  def test_200_with_good_bearer
    with_env("UPSTATE_HEALTH_TOKEN" => TOKEN) do
      res = get_health(token: TOKEN)
      assert_equal 200, res.status
      assert_equal "no-store", res.headers["cache-control"]
      assert_equal 1, JSON.parse(res.body)["schema"]
    end
  end

  def test_railtie_mounts_route_on_the_app
    with_env("UPSTATE_HEALTH_TOKEN" => TOKEN) do
      assert_equal 200, get_health(token: TOKEN, app: DummyApp).status
    end
    with_env("UPSTATE_HEALTH_TOKEN" => nil) do
      assert_equal 404, get_health(token: TOKEN, app: DummyApp).status
    end
  end
end
