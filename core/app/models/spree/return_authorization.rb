module Spree
  class ReturnAuthorization < Spree::Base
    belongs_to :order, class_name: 'Spree::Order', inverse_of: :return_authorizations

    has_many :return_items, inverse_of: :return_authorization, dependent: :destroy
    has_many :inventory_units, through: :return_items, dependent: :nullify
    has_many :customer_returns, through: :return_items

    belongs_to :stock_location
    belongs_to :reason, class_name: 'Spree::ReturnReason', foreign_key: :return_reason_id

    before_create :generate_number

    after_save :generate_expedited_exchange_reimbursements

    accepts_nested_attributes_for :return_items, allow_destroy: true

    validates :order, presence: true
    validates :stock_location, presence: true
    validate :must_have_shipped_units, on: :create
    validate :no_previously_exchanged_inventory_units, on: :create


    # These are called prior to generating expedited exchanges shipments.
    # Should respond to a "call" method that takes the list of return items
    class_attribute :pre_expedited_exchange_hooks
    self.pre_expedited_exchange_hooks = []

    state_machine initial: :authorized do
      before_transition to: :canceled, do: :cancel_return_items

      event :cancel do
        transition to: :canceled, from: :authorized, if: lambda { |return_authorization| return_authorization.can_cancel_return_items? }
      end

    end

    extend DisplayMoney
    money_methods :pre_tax_total

    self.whitelisted_ransackable_attributes = ['memo']

    def pre_tax_total
      return_items.sum(:pre_tax_amount)
    end

    def currency
      order.nil? ? Spree::Config[:currency] : order.currency
    end

    def refundable_amount
      order.pre_tax_item_amount + order.promo_total
    end

    def customer_returned_items?
      customer_returns.exists?
    end

    def can_cancel_return_items?
      return_items.any?(&:can_cancel?) || return_items.blank?
    end

    private

      def must_have_shipped_units
        if order.nil? || order.inventory_units.shipped.none?
          errors.add(:order, Spree.t(:has_no_shipped_units))
        end
      end

      def generate_number
        self.number ||= loop do
          random = "RA#{Array.new(9){rand(9)}.join}"
          break random unless self.class.exists?(number: random)
        end
      end

      def no_previously_exchanged_inventory_units
        if return_items.map(&:inventory_unit).any?(&:exchange_requested?)
          errors.add(:base, Spree.t(:return_items_cannot_be_created_for_inventory_units_that_are_already_awaiting_exchange))
        end
      end

      def cancel_return_items
        return_items.each { |item| item.cancel! if item.can_cancel? }
      end

      def generate_expedited_exchange_reimbursements
        return unless Spree::Config[:expedited_exchanges]

        items_to_exchange = return_items.select(&:exchange_required?)
        items_to_exchange.each(&:attempt_accept)
        items_to_exchange.select!(&:accepted?)

        return if items_to_exchange.blank?

        pre_expedited_exchange_hooks.each { |h| h.call items_to_exchange }

        reimbursement = Reimbursement.new(return_items: items_to_exchange, order: order)

        if reimbursement.save
          reimbursement.perform!
        else
          errors.add(:base, reimbursement.errors.full_messages)
          raise ActiveRecord::RecordInvalid.new(self)
        end

      end
  end
end
