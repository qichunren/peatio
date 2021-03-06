class Withdraw < ActiveRecord::Base
  include Concerns::Withdraws::Bank
  include Concerns::Withdraws::Satoshi

  extend Enumerize
  enumerize :state, in: {
    :apply => 10, :wait => 100, :reject => 110,
    :examined => 210, :examined_warning => 220,
    :transact => 300,
    :coin_ready => 400, :coin_done => 410,
    :done => 500, :cancel => 0}, scope: true
  enumerize :address_type, in: WithdrawChannel.enumerize
  enumerize :currency, in: Currency.codes, scope: true

  COMPLETED_STATES = [:done, :reject, :cancel]

  belongs_to :member
  belongs_to :account
  has_many :account_versions, :as => :modifiable
  attr_accessor :withdraw_address_id, :password, :sum

  after_create :generate_sn
  before_validation :populate_fields_from_address, :fix_fee
  after_update :bust_last_done_cache, if: :state_changed_to_done

  validates :address_type, :address, :address_label,
    :amount, :fee, :account, :currency, :member, presence: true

  validates :fee, numericality: {greater_than_or_equal_to: 0}
  validates :amount, numericality: {greater_than: 0}

  validates :sum, presence: true, on: :create
  validates :sum, numericality: {greater_than: 0}, on: :create
  validates :password, presence: true, on: :create
  validates :tx_id, presence: true, uniqueness: true, on: :update

  validate :ensure_account_balance, on: :create
  validate :validate_password, on: :create

  def coin?
    address_type.try(:satoshi?) or address_type.try(:protoshares?)
  end

  def examine
    Resque.enqueue(Job::Examine, self.id) if self.state.wait?
  end

  def position_in_queue
    last_done = Rails.cache.fetch(last_completed_withdraw_cache_key) do
      self.class.
        with_state(*COMPLETED_STATES).
        where(address_type: address_type.value).
        maximum(:id)
    end

    self.class.where("id > ? AND id <= ?", (last_done || 0), id).
      where(address_type: address_type.value).
      count
  end

  alias_attribute :withdraw_id, :sn

  def generate_sn
    id_part = sprintf '%04d', id
    date_part = created_at.strftime('%y%m%d%H%M')
    self.sn = "#{date_part}#{id_part}"
    update_column(:sn, sn)
  end

  def sum
    @sum || ((self.amount || 0.to_d) + (self.fee || 0.to_d))
  end

  private

  def last_completed_withdraw_cache_key
    "last_completed_withdraw_id_for_#{address_type}"
  end

  def validate_password
    unless self.member.identity.authenticate(self.password)
      errors.clear
      errors.add(:password, :match)
    end
  end

  def ensure_account_balance
    if self.sum > account.balance
      errors.add(:sum, :poor)
    end
  end

  def populate_fields_from_address
    withdraw_address = WithdrawAddress.where(id: withdraw_address_id).first
    return if withdraw_address.nil?

    account = withdraw_address.account
    return if account.nil?

    self.account_id = account.id
    self.currency = account.currency
    self.address = withdraw_address.address
    self.address_type = withdraw_address.category
    self.address_label = withdraw_address.label
  end

  def fix_fee
    self.sum = self.sum.to_d

    if self.respond_to? valid_method = "_valid_#{self.address_type}_sum"
      error = self.instance_eval(valid_method)
      self.errors.add('sum', "#{self.address_type}_#{error}".to_sym) if error
    end

    if self.respond_to? fee_method = "_fix_#{self.address_type}_fee"
      self.instance_eval(fee_method)
    end

    # withdraw fee inner cost
    self.fee ||= 0.0
    self.amount = (self.sum - self.fee)
  end

  def state_changed_to_done
    state_changed? && COMPLETED_STATES.include?(state.to_sym)
  end

  def bust_last_done_cache
    Rails.cache.delete(last_completed_withdraw_cache_key)
  end
end
